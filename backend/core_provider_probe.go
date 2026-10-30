package main

import (
	"encoding/json"
	"strings"
)

// Virtual rows measure a concrete node. The parent row continues to measure
// the provider's complete routing policy, including any intentional DIRECT rule.
func prepareProviderNodeProbe(server ServerConfig) (ServerConfig, error) {
	if server.NativeTarget == "" {
		return server, nil
	}
	core := server.SourceProfileCore
	if core != "sing-box" && core != "mihomo" {
		return ServerConfig{}, providerProbeUnsupported("неизвестное ядро")
	}
	// Validate the original graph with the production sanitizer. This performs
	// no downloads or core execution and cannot modify the stored RawMessage.
	// App-level domain exceptions must not bypass the node being measured.
	validated := server
	validated.RuntimeDirectDomains = nil
	raw, err := buildCoreConfig(core, validated, 10808, 10809, "local")
	if err != nil {
		return ServerConfig{}, err
	}
	var original object
	if json.Unmarshal(raw, &original) != nil {
		return ServerConfig{}, providerProbeUnsupported("неверный граф профиля")
	}
	primary := providerPrimarySelector(core, original)
	if primary == nil {
		return ServerConfig{}, providerProbeUnsupported("неоднозначная основная группа")
	}
	key, nameKey, membersKey := "outbounds", "tag", "outbounds"
	if core == "mihomo" {
		key, nameKey, membersKey = "proxies", "name", "proxies"
	}
	primaryName := str(primary[nameKey])
	graph := &providerProbeGraph{core: core, primary: primaryName, target: server.NativeTarget, entries: map[string]object{}, state: map[string]int{}, keep: map[string]bool{}}
	keys := []string{key}
	if core == "mihomo" {
		keys = append(keys, "proxy-groups")
	}
	for _, key := range keys {
		entries, err := providerObjects(original[key], key, false)
		if err != nil {
			return ServerConfig{}, err
		}
		for _, entry := range entries {
			name := str(entry[nameKey])
			if name == "" || graph.entries[name] != nil {
				return ServerConfig{}, providerProbeUnsupported("повторяющиеся или пустые имена зависимостей")
			}
			graph.entries[name] = entry
		}
	}
	if err := graph.visit(primaryName); err != nil {
		return ServerConfig{}, err
	}
	// DNS is retained verbatim. Its references must remain valid; a download or
	// dynamic group needed by DNS is an explicit unsupported probe dependency.
	if err := graph.dnsDependencies(original["dns"]); err != nil {
		return ServerConfig{}, err
	}
	result := object{}
	if core == "sing-box" {
		for _, key := range []string{"dns", "experimental"} {
			if value, exists := original[key]; exists {
				result[key] = value
			}
		}
		route := object{"final": primaryName}
		for _, key := range []string{"default_domain_resolver", "auto_detect_interface", "override_android_vpn"} {
			if value, exists := obj(original["route"])[key]; exists {
				route[key] = value
			}
		}
		result["route"] = route
	} else {
		for _, key := range []string{"dns", "hosts", "ipv6", "tcp-concurrent", "unified-delay", "global-client-fingerprint", "keep-alive-idle", "keep-alive-interval", "disable-keep-alive"} {
			if value, exists := original[key]; exists {
				result[key] = value
			}
		}
		result["mode"], result["rules"] = "rule", []any{"MATCH," + primaryName}
	}
	for _, key := range keys {
		kept := []any{}
		for _, value := range original[key].([]any) {
			entry := obj(value)
			name := str(entry[nameKey])
			if !graph.keep[name] {
				continue
			}
			if name == primaryName || (core == "sing-box" && entry["type"] == "selector") || (core == "mihomo" && entry["type"] == "select") {
				member := server.NativeTarget
				if name != primaryName {
					member = str(entry[membersKey].([]any)[0])
				}
				entry = object{"type": entry["type"], nameKey: name, membersKey: []any{member}}
				if gUDP, exists := obj(value)["disable-udp"]; exists {
					if _, ok := gUDP.(bool); !ok {
						return ServerConfig{}, providerProbeUnsupported("тип disable-udp группы")
					}
					entry["disable-udp"] = gUDP
				}
				if core == "sing-box" {
					entry["default"] = member
				}
			}
			kept = append(kept, entry)
		}
		result[key] = kept
	}
	prepared := server
	prepared.RuntimeDirectDomains = nil
	prepared.Profile, err = json.Marshal(result)
	if err != nil {
		return ServerConfig{}, err
	}
	return prepared, nil
}

func providerProbeUnsupported(detail string) error {
	return fail(422, "Нельзя проверить выбранный узел отдельно: "+detail+". Проверьте профиль провайдера целиком.")
}

type providerProbeGraph struct {
	core, primary, target string
	entries               map[string]object
	state                 map[string]int
	keep                  map[string]bool
}

func (g *providerProbeGraph) visit(name string) error {
	if g.core == "mihomo" && name == "DIRECT" {
		return nil
	}
	if g.state[name] == 1 {
		return providerProbeUnsupported("циклическая зависимость узла")
	}
	if g.state[name] == 2 {
		return nil
	}
	entry := g.entries[name]
	if entry == nil {
		return providerProbeUnsupported("отсутствующая зависимость узла или DNS")
	}
	if len(g.keep) >= 128 {
		return providerProbeUnsupported("слишком много зависимостей")
	}
	g.state[name] = 1
	g.keep[name] = true
	kind := str(entry["type"])
	memberKey := "outbounds"
	if g.core == "mihomo" {
		memberKey = "proxies"
	}
	if name == g.primary {
		if err := g.visit(g.target); err != nil {
			return err
		}
	} else if kind == "selector" || kind == "select" {
		members, ok := entry[memberKey].([]any)
		if !ok || len(members) != 1 {
			return providerProbeUnsupported("неоднозначная группа в цепочке узла или DNS")
		}
		for _, key := range []string{"include-all", "include-all-proxies", "include-all-providers"} {
			if value, exists := entry[key]; exists && value != false {
				return providerProbeUnsupported("динамическая группа в цепочке узла или DNS")
			}
		}
		for _, key := range []string{"filter", "exclude-filter", "exclude-type"} {
			if value, exists := entry[key]; exists && value != "" {
				return providerProbeUnsupported("фильтр группы в цепочке узла или DNS")
			}
		}
		member, ok := members[0].(string)
		if !ok {
			return providerProbeUnsupported("неверная группа зависимостей")
		}
		if value := str(entry["default"]); value != "" && value != member {
			return providerProbeUnsupported("неоднозначный выбор группы")
		}
		if value := str(entry["default-selected"]); value != "" && value != member {
			return providerProbeUnsupported("неоднозначный выбор группы")
		}
		if err := g.visit(member); err != nil {
			return err
		}
	} else if kind == "urltest" || kind == "url-test" || kind == "fallback" || kind == "load-balance" || kind == "relay" {
		return providerProbeUnsupported("автоматическая группа в цепочке узла или DNS")
	}
	dependencyKey := "detour"
	if g.core == "mihomo" {
		dependencyKey = "dialer-proxy"
	}
	if value, exists := entry[dependencyKey]; exists {
		dependency, ok := value.(string)
		if !ok {
			return providerProbeUnsupported("тип зависимости узла")
		}
		if dependency != "" {
			if err := g.visit(dependency); err != nil {
				return err
			}
		}
	}
	g.state[name] = 2
	return nil
}

func (g *providerProbeGraph) dnsDependencies(value any) error {
	switch value := value.(type) {
	case map[string]any:
		for key, child := range value {
			lower := strings.ToLower(key)
			if lower == "geoip" && child == false {
				continue
			}
			if lower == "geoip-code" {
				continue
			}
			if lower == "geosite" {
				if list, ok := child.([]any); ok && len(list) == 0 {
					continue
				}
			}
			if strings.Contains(lower, "rule_set") || strings.Contains(lower, "rule-set") || strings.Contains(lower, "geosite") || lower == "geoip" {
				return providerProbeUnsupported("DNS требует внешние правила или геоданные")
			}
			if g.core == "sing-box" && key == "detour" {
				name, ok := child.(string)
				if !ok {
					return providerProbeUnsupported("тип DNS detour")
				}
				if name != "" {
					if err := g.visit(name); err != nil {
						return err
					}
				}
			}
			if err := g.dnsDependencies(child); err != nil {
				return err
			}
		}
	case []any:
		for _, child := range value {
			if err := g.dnsDependencies(child); err != nil {
				return err
			}
		}
	case string:
		lower := strings.ToLower(value)
		if strings.Contains(value, "#") || strings.HasPrefix(lower, "geosite:") || strings.HasPrefix(lower, "geoip:") || strings.HasPrefix(lower, "rule-set:") || strings.HasPrefix(strings.ToUpper(value), "RULE-SET,") {
			return providerProbeUnsupported("неподдерживаемая DNS policy/group зависимость")
		}
	}
	return nil
}
