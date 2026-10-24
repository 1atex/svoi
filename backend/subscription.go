package backend

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"
)

type ServerInfo struct {
	SubscriptionID string `json:"subscriptionId,omitempty"`
	ID             string `json:"id"`
	Name           string `json:"name"`
	Protocol       string `json:"protocol"`
	Address        string `json:"address"`
	Port           int    `json:"port"`
	Network        string `json:"network"`
	Security       string `json:"security"`
	FullProfile    bool   `json:"fullProfile,omitempty"`
	NodeCount      int    `json:"nodeCount,omitempty"`
}
type ServerConfig struct {
	ServerInfo
	RuntimeApps *AppRouting     `json:"-"`
	Outbound    json.RawMessage `json:"outbound"`
	Profile     json.RawMessage `json:"profile,omitempty"`
}
type ParsedSubscription struct {
	Servers  []ServerConfig
	Format   string
	Warnings []string
}
type object = map[string]any

func decodeBase64(s string) ([]byte, error) {
	s = strings.Join(strings.Fields(s), "")
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		if b, e := enc.DecodeString(s); e == nil {
			return b, nil
		}
	}
	return nil, errors.New("некорректный Base64")
}
func parseSubscription(data []byte) (ParsedSubscription, error) {
	p := ParsedSubscription{Format: "URI list", Warnings: []string{}, Servers: []ServerConfig{}}
	s := strings.TrimSpace(strings.TrimPrefix(string(data), "\ufeff"))
	if !strings.HasPrefix(s, "{") && !strings.HasPrefix(s, "[") && !strings.Contains(s, "://") {
		b, err := decodeBase64(s)
		if err != nil {
			return p, fail(422, "Не удалось прочитать подписку: ожидается список ссылок, Base64 или Xray JSON")
		}
		s = strings.TrimSpace(string(b))
		p.Format = "Base64"
	}
	seen := map[string]bool{}
	add := func(server ServerConfig) {
		if !seen[server.ID] {
			seen[server.ID] = true
			p.Servers = append(p.Servers, server)
		}
	}
	if strings.HasPrefix(s, "{") || strings.HasPrefix(s, "[") {
		p.Format = "Xray JSON"
		var raw any
		if json.Unmarshal([]byte(s), &raw) != nil {
			return p, fail(422, "Некорректный Xray JSON")
		}
		configs, ok := raw.([]any)
		if !ok {
			configs = []any{raw}
		}
		for ci, c := range configs {
			m, ok := c.(map[string]any)
			if !ok {
				p.Warnings = append(p.Warnings, fmt.Sprintf("Конфигурация %d: ожидается объект", ci+1))
				continue
			}
			outbounds, ok := m["outbounds"].([]any)
			if ok {
				server, err := serverFromProfile(m, ci+1)
				if err != nil {
					p.Warnings = append(p.Warnings, fmt.Sprintf("Конфигурация %d: %s", ci+1, err))
				} else {
					add(server)
				}
				continue
			}
			if !ok {
				if _, ok = m["protocol"]; ok {
					outbounds = []any{m}
				}
			}
			for oi, ob := range outbounds {
				out, ok := ob.(map[string]any)
				if !ok {
					continue
				}
				protocol := str(out["protocol"])
				if serviceOutbound(protocol) {
					continue
				}
				name := str(m["remarks"])
				if name == "" {
					name = str(out["tag"])
				}
				if name == "" {
					name = fmt.Sprintf("Сервер %d.%d", ci+1, oi+1)
				}
				server, err := serverFromOutbound(name, out)
				if err != nil {
					p.Warnings = append(p.Warnings, fmt.Sprintf("Конфигурация %d.%d: %s", ci+1, oi+1, err))
					continue
				}
				add(server)
			}
		}
	} else {
		for i, line := range strings.Split(s, "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			server, err := parseServerURI(line)
			if err != nil {
				p.Warnings = append(p.Warnings, fmt.Sprintf("Строка %d: %s", i+1, err))
				continue
			}
			add(server)
		}
	}
	if len(p.Servers) == 0 {
		msg := "В подписке нет поддерживаемых серверов"
		if len(p.Warnings) > 0 {
			msg += ". " + strings.Join(p.Warnings[:min(3, len(p.Warnings))], "; ")
		}
		return p, fail(422, msg)
	}
	if len(p.Servers) > 2000 {
		return p, fail(413, "В подписке больше 2000 серверов")
	}
	if len(p.Warnings) > 30 {
		p.Warnings = append(p.Warnings[:30], "Остальные ошибки скрыты")
	}
	return p, nil
}
func str(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case int:
		return strconv.Itoa(x)
	case float64:
		return strconv.FormatFloat(x, 'f', -1, 64)
	case json.Number:
		return x.String()
	}
	return ""
}
func number(v any) int { i, _ := strconv.Atoi(str(v)); return i }
func obj(v any) object {
	m, _ := v.(map[string]any)
	if m == nil {
		return object{}
	}
	return m
}
func firstObject(v any) object {
	a, _ := v.([]any)
	if len(a) == 0 {
		return object{}
	}
	return obj(a[0])
}

func serverFromOutbound(name string, out object) (ServerConfig, error) {
	protocol := str(out["protocol"])
	switch protocol {
	case "vless", "vmess", "trojan", "shadowsocks", "socks", "http", "hysteria":
	default:
		return ServerConfig{}, errors.New("протокол не поддерживается: " + protocol)
	}
	if out["proxySettings"] != nil || out["sendThrough"] != nil {
		return ServerConfig{}, errors.New("цепочки proxySettings/sendThrough требуют отдельного профиля маршрутизации")
	}
	settings := obj(out["settings"])
	endpoint := settings
	if settings["vnext"] != nil {
		endpoint = firstObject(settings["vnext"])
	} else if settings["servers"] != nil {
		endpoint = firstObject(settings["servers"])
	}
	address := str(endpoint["address"])
	port := number(endpoint["port"])
	if address == "" || port < 1 || port > 65535 {
		return ServerConfig{}, errors.New("не указан адрес сервера или неверный порт")
	}
	stream := obj(out["streamSettings"])
	network := str(stream["network"])
	if network == "" {
		network = str(stream["method"])
	}
	if network == "" {
		network = "tcp"
	}
	security := str(stream["security"])
	if security == "" {
		security = "none"
	}
	if name == "" {
		name = net.JoinHostPort(address, strconv.Itoa(port))
	}

	out["tag"] = "proxy"
	b, err := json.Marshal(out)
	if err != nil {
		return ServerConfig{}, err
	}
	return ServerConfig{ServerInfo: ServerInfo{ID: digest(string(b))[:24], Name: name, Protocol: protocol, Address: address, Port: port, Network: network, Security: security}, Outbound: b}, nil
}
func parseServerURI(raw string) (ServerConfig, error) {
	if strings.HasPrefix(raw, "vmess://") {
		return parseVMess(raw)
	}
	if strings.HasPrefix(raw, "ss://") {
		return parseShadowsocks(raw)
	}
	u, err := url.Parse(raw)
	if err != nil {
		return ServerConfig{}, errors.New("некорректная ссылка")
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil || port < 1 || port > 65535 || u.Hostname() == "" {
		return ServerConfig{}, errors.New("неверный адрес или порт")
	}
	if u.User == nil {
		return ServerConfig{}, errors.New("в ссылке нет учётных данных")
	}
	credential := u.User.Username()
	q := u.Query()
	settings := object{}
	protocol := u.Scheme
	switch protocol {
	case "vless":
		if credential == "" {
			return ServerConfig{}, errors.New("пустой VLESS ID")
		}
		encryption := q.Get("encryption")
		if encryption == "" {
			encryption = "none"
		}
		user := object{"id": credential, "encryption": encryption}
		if flow := q.Get("flow"); flow != "" {
			user["flow"] = flow
		}
		settings["vnext"] = []any{object{"address": u.Hostname(), "port": port, "users": []any{user}}}
	case "trojan":
		if credential == "" {
			return ServerConfig{}, errors.New("пустой пароль Trojan")
		}
		settings["servers"] = []any{object{"address": u.Hostname(), "port": port, "password": credential}}
		if q.Get("security") == "" {
			q.Set("security", "tls")
		}
	case "socks", "socks5", "http":
		if protocol == "socks5" {
			protocol = "socks"
		}
		endpoint := object{"address": u.Hostname(), "port": port}
		if credential != "" {
			password, _ := u.User.Password()
			endpoint["users"] = []any{object{"user": credential, "pass": password}}
		}
		settings["servers"] = []any{endpoint}
	default:
		return ServerConfig{}, errors.New("протокол ссылки не поддерживается: " + protocol)
	}
	stream, err := streamFromQuery(q)
	if err != nil {
		return ServerConfig{}, err
	}
	return serverFromOutbound(u.Fragment, object{"protocol": protocol, "settings": settings, "streamSettings": stream})
}
func streamFromQuery(q url.Values) (object, error) {
	network := q.Get("type")
	if network == "" {
		network = "tcp"
	}
	stream := object{"network": network}
	security := q.Get("security")
	if security == "" {
		security = "none"
	}
	stream["security"] = security
	sni := q.Get("sni")
	if sni == "" {
		sni = q.Get("serverName")
	}
	fp := q.Get("fp")
	if fp == "" {
		fp = "chrome"
	}
	switch security {
	case "none":
	case "tls":
		tls := object{"fingerprint": fp}
		if sni != "" {
			tls["serverName"] = sni
		}
		if alpn := q.Get("alpn"); alpn != "" {
			tls["alpn"] = strings.Split(alpn, ",")
		}
		if q.Get("allowInsecure") == "1" || q.Get("insecure") == "1" {
			tls["allowInsecure"] = true
		}
		stream["tlsSettings"] = tls
	case "reality":
		key := q.Get("pbk")
		if key == "" {
			return nil, errors.New("Reality: отсутствует публичный ключ pbk")
		}
		if sni == "" {
			return nil, errors.New("Reality: отсутствует sni")
		}
		stream["realitySettings"] = object{"fingerprint": fp, "serverName": sni, "publicKey": key, "shortId": q.Get("sid"), "spiderX": q.Get("spx")}
	default:
		return nil, errors.New("неподдерживаемая защита транспорта: " + security)
	}
	switch network {
	case "tcp", "raw":
		if q.Get("headerType") == "http" {
			tcp := object{"header": object{"type": "http", "request": object{"path": []string{defaultString(q.Get("path"), "/")}, "headers": object{"Host": strings.Split(q.Get("host"), ",")}}}}
			stream["tcpSettings"] = tcp
		} else if q.Get("headerType") != "" && q.Get("headerType") != "none" {
			return nil, errors.New("неподдерживаемый TCP headerType")
		}
	case "ws", "websocket":
		stream["network"] = "ws"
		ws := object{"path": defaultString(q.Get("path"), "/")}
		if h := q.Get("host"); h != "" {
			ws["headers"] = object{"Host": h}
		}
		stream["wsSettings"] = ws
	case "grpc":
		stream["grpcSettings"] = object{"serviceName": q.Get("serviceName"), "multiMode": q.Get("mode") == "multi"}
	case "httpupgrade":
		stream["httpupgradeSettings"] = object{"host": q.Get("host"), "path": defaultString(q.Get("path"), "/")}
	case "xhttp", "splithttp":
		stream["network"] = "xhttp"
		x := object{"host": q.Get("host"), "path": defaultString(q.Get("path"), "/"), "mode": defaultString(q.Get("mode"), "auto")}
		if extra := q.Get("extra"); extra != "" {
			var v object
			if json.Unmarshal([]byte(extra), &v) != nil {
				return nil, errors.New("неверный JSON в xhttp extra")
			}
			x["extra"] = v
		}
		stream["xhttpSettings"] = x
	default:
		return nil, errors.New("транспорт не поддерживается: " + network)
	}
	return stream, nil
}
func defaultString(s, d string) string {
	if s == "" {
		return d
	}
	return s
}
func parseVMess(raw string) (ServerConfig, error) {
	b, err := decodeBase64(strings.TrimPrefix(raw, "vmess://"))
	if err != nil {
		return ServerConfig{}, err
	}
	var v object
	if json.Unmarshal(b, &v) != nil {
		return ServerConfig{}, errors.New("неверный VMess JSON")
	}
	if str(v["id"]) == "" {
		return ServerConfig{}, errors.New("VMess: пустой ID")
	}
	q := url.Values{}
	q.Set("type", defaultString(str(v["net"]), "tcp"))
	for _, key := range []string{"host", "path", "sni", "alpn", "fp"} {
		q.Set(key, str(v[key]))
	}
	q.Set("headerType", str(v["type"]))
	q.Set("serviceName", str(v["path"]))
	q.Set("security", defaultString(str(v["tls"]), "none"))
	stream, err := streamFromQuery(q)
	if err != nil {
		return ServerConfig{}, err
	}
	out := object{"protocol": "vmess", "settings": object{"vnext": []any{object{"address": str(v["add"]), "port": number(v["port"]), "users": []any{object{"id": str(v["id"]), "alterId": number(v["aid"]), "security": defaultString(str(v["scy"]), "auto")}}}}}, "streamSettings": stream}
	return serverFromOutbound(str(v["ps"]), out)
}
func parseShadowsocks(raw string) (ServerConfig, error) {
	payload := strings.TrimPrefix(raw, "ss://")
	if !strings.Contains(strings.SplitN(payload, "#", 2)[0], "@") {
		parts := strings.SplitN(payload, "#", 2)
		decoded, err := decodeBase64(parts[0])
		if err != nil {
			return ServerConfig{}, err
		}
		raw = "ss://" + string(decoded)
		if len(parts) == 2 {
			raw += "#" + parts[1]
		}
	}
	u, err := url.Parse(raw)
	if err != nil || u.User == nil {
		return ServerConfig{}, errors.New("неверная Shadowsocks-ссылка")
	}
	if u.Query().Get("plugin") != "" {
		return ServerConfig{}, errors.New("Shadowsocks plugin в этой версии не поддерживается")
	}
	method := u.User.Username()
	password, hasPassword := u.User.Password()
	if !hasPassword {
		decoded, err := decodeBase64(method)
		if err != nil {
			return ServerConfig{}, err
		}
		parts := strings.SplitN(string(decoded), ":", 2)
		if len(parts) != 2 {
			return ServerConfig{}, errors.New("Shadowsocks: нет пароля")
		}
		method, password = parts[0], parts[1]
	}
	port, _ := strconv.Atoi(u.Port())
	return serverFromOutbound(u.Fragment, object{"protocol": "shadowsocks", "settings": object{"servers": []any{object{"address": u.Hostname(), "port": port, "method": method, "password": password}}}})
}

func buildBaseXrayConfig(server ServerConfig, socksPort, httpPort int, mode string) ([]byte, error) {
	if len(server.Profile) > 0 {
		return buildProfileConfig(server.Profile, socksPort, httpPort, mode)
	}
	var outbound object
	if err := json.Unmarshal(server.Outbound, &outbound); err != nil {
		return nil, err
	}
	inbounds := []any{object{"tag": "socks-in", "listen": "127.0.0.1", "port": socksPort, "protocol": "socks", "settings": object{"auth": "noauth", "udp": true}}, object{"tag": "http-in", "listen": "127.0.0.1", "port": httpPort, "protocol": "http", "settings": object{}}}
	if mode == "tun" {
		inbounds = append(inbounds, tunInbound("tun-in"))
	}
	config := object{"log": object{"loglevel": "warning"}, "inbounds": inbounds, "outbounds": []any{outbound}}
	if mode == "tun" {
		configureTunDNS(config, "tun-in")
	}
	return json.MarshalIndent(config, "", "  ")
}
