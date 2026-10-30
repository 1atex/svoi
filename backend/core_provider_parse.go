package main

import (
	"bytes"
	"encoding/json"
	"io"
	"math"
	"net/http"
	"regexp"
	"strings"
	"unicode/utf8"

	"go.yaml.in/yaml/v3"
)

const nativeProviderMaxBytes = 4 << 20
const nativeProviderMaxDepth = 64
const nativeProviderMaxNodes = 100000

// Parsing stores the complete provider graph. Runtime validation and local
// listener normalization happen separately, before a core is allowed to start.
func parseSubscriptionWithFormat(data []byte, format string) (ParsedSubscription, error) {
	format = strings.ToLower(strings.TrimSpace(format))
	if format == "" {
		format = "auto"
	}
	if format != "auto" && format != "sing-box" && format != "mihomo" {
		return ParsedSubscription{}, fail(422, "Неизвестный формат подписки: выберите авто, sing-box или Mihomo")
	}
	if len(data) > nativeProviderMaxBytes {
		return ParsedSubscription{}, fail(413, "Подписка превышает 4 МиБ")
	}
	if !utf8.Valid(data) {
		return ParsedSubscription{}, fail(422, "Подписка должна содержать текст UTF-8")
	}
	text := strings.TrimSpace(strings.TrimPrefix(string(data), "\ufeff"))
	if nativeProviderHTML(text) {
		return ParsedSubscription{}, fail(422, "Провайдер вернул HTML-страницу вместо подписки. Проверьте ссылку и авторизацию")
	}
	headers := nativeProviderMetadata(text)
	probe := text
	encoded := false
	// Existing URI and Base64/Xray parsing remains the authority for legacy
	// subscriptions. Decoding here only detects a native profile or an HTML page.
	legacyText := stripSubscriptionMetadata(text, make(http.Header))
	if nativeProviderURI(legacyText) {
		return nativeProviderLegacy(data, format)
	}
	if !strings.HasPrefix(legacyText, "{") && !strings.HasPrefix(legacyText, "[") {
		if decoded, err := decodeBase64(legacyText); err == nil && utf8.Valid(decoded) {
			probe = strings.TrimSpace(strings.TrimPrefix(string(decoded), "\ufeff"))
			encoded = true
			if nativeProviderHTML(probe) {
				return ParsedSubscription{}, fail(422, "Провайдер вернул HTML-страницу вместо подписки")
			}
			if nativeProviderURI(stripSubscriptionMetadata(probe, make(http.Header))) {
				return nativeProviderLegacy(data, format)
			}
			for key, values := range nativeProviderMetadata(probe) {
				headers[key] = values
			}
		}
	}
	value, err := nativeProviderDocument([]byte(probe))
	if err != nil {
		return ParsedSubscription{}, err
	}
	profile, objectOK := value.(map[string]any)
	if !objectOK {
		return nativeProviderLegacy(data, format)
	}
	core, xray, ambiguous := nativeProviderShape(profile)
	if ambiguous {
		return ParsedSubscription{}, fail(422, "В подписке смешаны структуры Xray, sing-box или Mihomo; формат неоднозначен")
	}
	if core != "" && format != "auto" && core != format {
		return ParsedSubscription{}, fail(422, "Провайдер вернул профиль другого ядра; выберите его формат или автоопределение")
	}
	if core == "" {
		if xray {
			return nativeProviderLegacy(data, format)
		}
		if format == "sing-box" {
			if _, exists := profile["outbounds"]; exists {
				core = "sing-box"
			}
		}
		if format == "mihomo" {
			if _, exists := profile["proxy-providers"]; exists {
				core = "mihomo"
			}
		}
		if core == "" {
			if _, exists := profile["outbounds"]; exists {
				return ParsedSubscription{}, fail(422, "Не удалось однозначно определить формат outbounds; выберите формат подписки")
			}
			return nativeProviderLegacy(data, format)
		}
	}
	server, err := nativeProviderServer(profile, core)
	if err != nil {
		return ParsedSubscription{}, err
	}
	label := "Mihomo"
	if core == "sing-box" {
		label = "sing-box"
	}
	if strings.HasPrefix(probe, "{") {
		label += " JSON"
	} else {
		label += " YAML"
	}
	if encoded {
		label += " (Base64)"
	}
	return ParsedSubscription{MetadataHeaders: headers, Servers: []ServerConfig{server}, Format: label, Warnings: []string{}}, nil
}

func nativeProviderLegacy(data []byte, requested string) (ParsedSubscription, error) {
	parsed, err := parseSubscription(data)
	if err == nil && requested != "auto" {
		name := "Mihomo"
		if requested == "sing-box" {
			name = "sing-box"
		}
		parsed.Warnings = append([]string{"Провайдер не выдал ожидаемый формат " + name + "; получена совместимая с Xray подписка. Исходные настройки сохранены"}, parsed.Warnings...)
	}
	return parsed, err
}

func nativeProviderHTML(text string) bool {
	return strings.HasPrefix(strings.TrimSpace(text), "<")
}

var nativeProviderSchemeRE = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9+.-]*://`)

func nativeProviderURI(text string) bool {
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		return nativeProviderSchemeRE.MatchString(line)
	}
	return false
}
func nativeProviderMetadata(text string) http.Header {
	// Only leading comments can be metadata. A '#' line inside a YAML block
	// scalar is string content and must never be removed from a password/value.
	comments := []string{}
	for _, line := range strings.Split(text, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed != "" && !strings.HasPrefix(trimmed, "#") {
			break
		}
		comments = append(comments, line)
	}
	headers := make(http.Header)
	stripSubscriptionMetadata(strings.Join(comments, "\n"), headers)
	return headers
}

func nativeProviderDocument(data []byte) (any, error) {
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	var document yaml.Node
	if decoder.Decode(&document) != nil || document.Kind != yaml.DocumentNode || len(document.Content) != 1 {
		return nil, fail(422, "Не удалось прочитать JSON/YAML подписки")
	}
	var trailing yaml.Node
	if decoder.Decode(&trailing) != io.EOF {
		return nil, fail(422, "Подписка должна содержать ровно один JSON/YAML документ")
	}
	count := 0
	return nativeProviderNode(document.Content[0], 0, &count)
}

func nativeProviderNode(node *yaml.Node, depth int, count *int) (any, error) {
	*count++
	if depth > nativeProviderMaxDepth || *count > nativeProviderMaxNodes {
		return nil, fail(422, "Структура JSON/YAML подписки слишком сложная")
	}
	if node.Kind == yaml.AliasNode || node.Anchor != "" {
		return nil, fail(422, "YAML-якоря и ссылки aliases в подписке не поддерживаются")
	}
	switch node.Kind {
	case yaml.MappingNode:
		if node.Tag != "!!map" || len(node.Content)%2 != 0 {
			return nil, fail(422, "Некорректный тип YAML-объекта подписки")
		}
		result := make(map[string]any, len(node.Content)/2)
		for i := 0; i < len(node.Content); i += 2 {
			key := node.Content[i]
			if key.Kind != yaml.ScalarNode || key.Tag != "!!str" || key.Anchor != "" {
				return nil, fail(422, "Ключи JSON/YAML подписки должны быть строками без merge-тегов")
			}
			if _, exists := result[key.Value]; exists {
				return nil, fail(422, "В JSON/YAML подписки есть повторяющиеся ключи")
			}
			*count++
			value, err := nativeProviderNode(node.Content[i+1], depth+1, count)
			if err != nil {
				return nil, err
			}
			result[key.Value] = value
		}
		return result, nil
	case yaml.SequenceNode:
		if node.Tag != "!!seq" {
			return nil, fail(422, "Неизвестный YAML-тег списка подписки")
		}
		result := make([]any, len(node.Content))
		for i, child := range node.Content {
			value, err := nativeProviderNode(child, depth+1, count)
			if err != nil {
				return nil, err
			}
			result[i] = value
		}
		return result, nil
	case yaml.ScalarNode:
		switch node.Tag {
		case "!!str":
			return node.Value, nil
		case "!!null", "!!bool", "!!int", "!!float":
		default:
			return nil, fail(422, "Неизвестный или неподдерживаемый YAML-тег значения подписки")
		}
		var value any
		if node.Decode(&value) != nil {
			return nil, fail(422, "Некорректное значение JSON/YAML подписки")
		}
		if f, ok := value.(float64); ok {
			if node.Tag == "!!int" || math.IsInf(f, 0) || math.IsNaN(f) {
				return nil, fail(422, "Число JSON/YAML подписки выходит за поддерживаемый диапазон")
			}
		}
		return value, nil
	default:
		return nil, fail(422, "Неподдерживаемая структура JSON/YAML подписки")
	}
}

func nativeProviderShape(profile object) (core string, xray, ambiguous bool) {
	_, mihomoProxies := profile["proxies"]
	_, mihomoGroups := profile["proxy-groups"]
	_, mihomoProviders := profile["proxy-providers"]
	mihomo := mihomoProxies || mihomoGroups || mihomoProviders
	sing := false
	if _, exists := profile["protocol"]; exists {
		xray = true
	}
	if outbounds, ok := profile["outbounds"].([]any); ok {
		for _, value := range outbounds {
			if out, ok := value.(map[string]any); ok {
				if _, exists := out["type"]; exists {
					sing = true
				}
				if _, exists := out["protocol"]; exists {
					xray = true
				}
			}
		}
	}
	if (sing && mihomo) || (xray && (sing || mihomo)) {
		return "", xray, true
	}
	if mihomo {
		return "mihomo", xray, false
	}
	if sing {
		return "sing-box", xray, false
	}
	return "", xray, false
}

func nativeProviderServer(profile object, core string) (ServerConfig, error) {
	key := "outbounds"
	name := "Профиль sing-box"
	if core == "mihomo" {
		key = "proxies"
		name = "Профиль Mihomo"
	}
	values := []any{}
	if value, exists := profile[key]; exists {
		var ok bool
		values, ok = value.([]any)
		if !ok {
			return ServerConfig{}, fail(422, "Неверный тип списка узлов в профиле провайдера")
		}
	} else if core == "sing-box" {
		return ServerConfig{}, fail(422, "В профиле sing-box отсутствует outbounds")
	}
	if core == "mihomo" {
		if value, exists := profile["proxy-providers"]; exists {
			providers, ok := value.(map[string]any)
			if !ok {
				return ServerConfig{}, fail(422, "Неверный тип proxy-providers в профиле Mihomo")
			}
			for _, provider := range providers {
				if _, ok := provider.(map[string]any); !ok {
					return ServerConfig{}, fail(422, "proxy-providers должен содержать объекты")
				}
			}
		}
		if value, exists := profile["proxy-groups"]; exists {
			groups, ok := value.([]any)
			if !ok {
				return ServerConfig{}, fail(422, "Неверный тип proxy-groups в профиле Mihomo")
			}
			for _, group := range groups {
				if _, ok := group.(map[string]any); !ok {
					return ServerConfig{}, fail(422, "proxy-groups должен содержать объекты")
				}
			}
		}
	}
	protocols := []string{}
	seen := map[string]bool{}
	nodes := 0
	for _, value := range values {
		proxy, ok := value.(map[string]any)
		if !ok {
			return ServerConfig{}, fail(422, "Список узлов профиля должен содержать объекты")
		}
		kind, ok := proxy["type"].(string)
		if !ok || strings.TrimSpace(kind) == "" {
			return ServerConfig{}, fail(422, "В узле профиля отсутствует строковый type")
		}
		kind = nativeProviderProtocol(kind)
		if nativeProviderService(kind) {
			continue
		}
		nodes++
		if nodes > 2000 {
			return ServerConfig{}, fail(413, "В профиле больше 2000 узлов")
		}
		if !seen[kind] {
			seen[kind] = true
			protocols = append(protocols, kind)
		}
	}
	raw, err := json.Marshal(profile)
	if err != nil {
		return ServerConfig{}, fail(422, "Не удалось сохранить JSON профиля провайдера")
	}
	if len(raw) > nativeProviderMaxBytes {
		return ServerConfig{}, fail(413, "Сохранённый JSON профиля превышает 4 МиБ")
	}
	protocol := "profile"
	if len(protocols) == 1 {
		protocol = protocols[0]
	}
	return ServerConfig{ServerInfo: ServerInfo{ID: digest(string(raw))[:24], Name: name, Protocol: protocol, Protocols: protocols, FullProfile: true, SourceProfileCore: core, NodeCount: nodes}, Profile: raw, Outbound: nil}, nil
}

var nativeProviderProtocolRE = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)

func nativeProviderProtocol(kind string) string {
	kind = strings.ToLower(strings.TrimSpace(kind))
	// Provider-controlled type values are not safe UI labels. Retain their raw
	// value in Profile for validation, but bound the public protocol metadata.
	if !nativeProviderProtocolRE.MatchString(kind) {
		return "unknown"
	}
	switch kind {
	case "ss":
		return "shadowsocks"
	case "ssr":
		return "shadowsocksr"
	case "hy2":
		return "hysteria2"
	case "socks5", "socks4":
		return "socks"
	}
	return kind
}
func nativeProviderService(kind string) bool {
	switch kind {
	case "direct", "block", "reject", "reject-drop", "dns", "selector", "urltest", "url-test", "select", "fallback", "load-balance", "relay", "pass", "compatible", "freedom", "blackhole", "loopback":
		return true
	}
	return false
}
