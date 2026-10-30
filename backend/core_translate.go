package main

import (
	"encoding/json"
	"net/url"
)

func nativeUnsupported(detail string) error {
	return fail(422, "Профиль не поддерживается выбранным ядром: "+detail+". Выберите Xray.")
}
func nativeKeys(m object, allowed ...string) error {
	for k := range m {
		found := false
		for _, a := range allowed {
			if k == a {
				found = true
				break
			}
		}
		if !found {
			return nativeUnsupported("параметр " + k)
		}
	}
	return nil
}
func nativeOne(v any, label string) (object, error) {
	a, ok := v.([]any)
	if !ok || len(a) != 1 {
		return nil, nativeUnsupported(label + ": требуется ровно один элемент")
	}
	m, ok := a[0].(map[string]any)
	if !ok {
		return nil, nativeUnsupported(label)
	}
	return m, nil
}

func nativeStringFields(m object, keys ...string) error {
	for _, k := range keys {
		if v, exists := m[k]; exists {
			if _, ok := v.(string); !ok {
				return nativeUnsupported("тип параметра " + k)
			}
		}
	}
	return nil
}
func nativeObjectField(m object, key string) error {
	if v, exists := m[key]; exists {
		if _, ok := v.(map[string]any); !ok {
			return nativeUnsupported("тип раздела " + key)
		}
	}
	return nil
}

// Xray only constructs its mux and XUDP managers when enabled is true. Provider
// exports commonly retain these inert defaults even when multiplexing is off.
func nativeDisabledMux(out object) error {
	if _, exists := out["mux"]; !exists {
		return nil
	}
	if err := nativeObjectField(out, "mux"); err != nil {
		return err
	}
	mux := obj(out["mux"])
	if err := nativeKeys(mux, "enabled", "concurrency", "xudpConcurrency", "xudpProxyUDP443"); err != nil {
		return err
	}
	if enabled, ok := mux["enabled"].(bool); !ok || enabled {
		return nativeUnsupported("включённый или неопределённый mux")
	}
	for _, key := range []string{"concurrency", "xudpConcurrency"} {
		if value, exists := mux[key]; exists {
			n, ok := value.(float64)
			if !ok || n < -32768 || n > 32767 || n != float64(int(n)) {
				return nativeUnsupported("тип параметра mux." + key)
			}
		}
	}
	if err := nativeStringFields(mux, "xudpProxyUDP443"); err != nil {
		return err
	}
	switch str(mux["xudpProxyUDP443"]) {
	case "", "reject", "allow", "skip":
	default:
		return nativeUnsupported("mux.xudpProxyUDP443")
	}
	return nil
}

// Translate only the deliberately bounded, lossless subset. Unknown fields are
// rejected at every level rather than silently changing a provider's settings.
func buildNativeCoreConfig(id string, server ServerConfig, sp, hp int, mode string) ([]byte, error) {
	if server.FullProfile || len(server.Profile) > 0 {
		return buildNativeProfileConfig(id, server, sp, hp, mode)
	}
	raw, err := buildNativeNodeConfig(id, server, sp, hp, mode)
	if err != nil {
		return nil, err
	}
	return nativeConfigWithDirectDomains(id, raw, server.RuntimeDirectDomains)
}

func buildNativeNodeConfig(id string, server ServerConfig, sp, hp int, mode string) ([]byte, error) {
	if id != "sing-box" && id != "mihomo" {
		return nil, nativeUnsupported("неизвестное ядро")
	}
	if mode != "local" && mode != "system" {
		return nil, nativeUnsupported("режим " + mode)
	}
	if server.RuntimeApps != nil && server.RuntimeApps.Mode != "" && server.RuntimeApps.Mode != "all" {
		return nil, nativeUnsupported("пользовательская маршрутизация")
	}
	var out object
	if err := json.Unmarshal(server.Outbound, &out); err != nil {
		return nil, nativeUnsupported("неверный JSON")
	}
	if err := nativeKeys(out, "protocol", "tag", "settings", "streamSettings", "mux"); err != nil {
		return nil, err
	}
	if err := nativeDisabledMux(out); err != nil {
		return nil, err
	}
	if err := nativeStringFields(out, "protocol", "tag"); err != nil {
		return nil, err
	}
	for _, k := range []string{"settings", "streamSettings"} {
		if err := nativeObjectField(out, k); err != nil {
			return nil, err
		}
	}
	protocol := str(out["protocol"])
	if protocol == "hysteria" {
		return nativeHysteriaConfig(id, out, sp, hp)
	}
	if protocol != "vless" && protocol != "vmess" && protocol != "trojan" && protocol != "shadowsocks" {
		return nil, nativeUnsupported("протокол " + protocol)
	}
	settings := obj(out["settings"])
	var endpoint, user object
	var err error
	if protocol == "vless" || protocol == "vmess" {
		if err = nativeKeys(settings, "vnext"); err != nil {
			return nil, err
		}
		endpoint, err = nativeOne(settings["vnext"], "vnext")
		if err != nil {
			return nil, err
		}
		if err = nativeKeys(endpoint, "address", "port", "users"); err != nil {
			return nil, err
		}
		user, err = nativeOne(endpoint["users"], "users")
		if err != nil {
			return nil, err
		}
		if protocol == "vless" {
			if err = nativeStringFields(user, "id", "encryption", "flow"); err != nil {
				return nil, err
			}
			if err = nativeKeys(user, "id", "encryption", "flow", "level", "email"); err != nil {
				return nil, err
			}
			if enc := str(user["encryption"]); enc != "" && enc != "none" {
				return nil, nativeUnsupported("VLESS encryption " + enc)
			}
			if flow := str(user["flow"]); flow != "" && flow != "xtls-rprx-vision" {
				return nil, nativeUnsupported("VLESS flow " + flow)
			}
		} else {
			if err = nativeStringFields(user, "id", "security"); err != nil {
				return nil, err
			}
			if err = nativeKeys(user, "id", "alterId", "security", "level", "email"); err != nil {
				return nil, err
			}
			if aid, exists := user["alterId"]; exists && str(aid) != "0" {
				return nil, nativeUnsupported("VMess legacy alterId")
			}
			cipher := defaultString(str(user["security"]), "auto")
			if cipher != "auto" && cipher != "none" && cipher != "aes-128-gcm" && cipher != "chacha20-poly1305" {
				return nil, nativeUnsupported("VMess cipher " + cipher)
			}
		}
		if str(user["id"]) == "" {
			return nil, nativeUnsupported("пустой UUID")
		}
	} else {
		if err = nativeKeys(settings, "servers"); err != nil {
			return nil, err
		}
		endpoint, err = nativeOne(settings["servers"], "servers")
		if err != nil {
			return nil, err
		}
		keys := []string{"address", "port", "password", "level", "email"}
		if protocol == "shadowsocks" {
			keys = append(keys, "method")
		}
		if err = nativeKeys(endpoint, keys...); err != nil {
			return nil, err
		}
		if str(endpoint["password"]) == "" {
			return nil, nativeUnsupported("пустой пароль")
		}
		if err = nativeStringFields(endpoint, "password", "method"); err != nil {
			return nil, err
		}
	}
	if err = nativeStringFields(endpoint, "address"); err != nil {
		return nil, err
	}
	address, port := str(endpoint["address"]), number(endpoint["port"])
	if address == "" || port < 1 || port > 65535 {
		return nil, nativeUnsupported("адрес или порт")
	}
	stream := obj(out["streamSettings"])
	if err = nativeStringFields(stream, "network", "security"); err != nil {
		return nil, err
	}
	network := defaultString(str(stream["network"]), "tcp")
	if network == "raw" {
		network = "tcp"
	}
	if network != "tcp" && network != "ws" && network != "grpc" {
		return nil, nativeUnsupported("транспорт " + network)
	}
	security := defaultString(str(stream["security"]), "none")
	if security != "none" && security != "tls" && security != "reality" {
		return nil, nativeUnsupported("защита " + security)
	}
	allowed := []string{"network", "security"}
	if network == "tcp" {
		allowed = append(allowed, "tcpSettings")
	} else {
		allowed = append(allowed, network+"Settings")
	}
	if security != "none" {
		allowed = append(allowed, security+"Settings")
	}
	if err = nativeKeys(stream, allowed...); err != nil {
		return nil, err
	}
	for _, key := range []string{network + "Settings", security + "Settings"} {
		if err = nativeObjectField(stream, key); err != nil {
			return nil, err
		}
	}
	transport := obj(stream[network+"Settings"])
	switch network {
	case "tcp":
		if err = nativeObjectField(transport, "header"); err != nil {
			return nil, err
		}
		if err = nativeKeys(transport, "header"); err != nil {
			return nil, err
		}
		header := obj(transport["header"])
		if err = nativeStringFields(header, "type"); err != nil {
			return nil, err
		}
		if err = nativeKeys(header, "type"); err != nil {
			return nil, err
		}
		if h := str(header["type"]); h != "" && h != "none" {
			return nil, nativeUnsupported("TCP header")
		}
	case "ws":
		if err = nativeStringFields(transport, "path"); err != nil {
			return nil, err
		}
		if err = nativeObjectField(transport, "headers"); err != nil {
			return nil, err
		}
		if err = nativeKeys(transport, "path", "headers"); err != nil {
			return nil, err
		}
		p, parseErr := url.Parse(str(transport["path"]))
		if parseErr != nil || p.Query().Has("ed") {
			return nil, nativeUnsupported("WebSocket early data/path")
		}
		for _, value := range obj(transport["headers"]) {
			if _, ok := value.(string); !ok {
				return nil, nativeUnsupported("WebSocket headers")
			}
		}
	case "grpc":
		if err = nativeStringFields(transport, "serviceName"); err != nil {
			return nil, err
		}
		if err = nativeKeys(transport, "serviceName", "multiMode"); err != nil {
			return nil, err
		}
		if multi, ok := transport["multiMode"].(bool); transport["multiMode"] != nil && (!ok || multi) {
			return nil, nativeUnsupported("gRPC multiMode")
		}
	}
	tls := obj(stream[security+"Settings"])
	if err = nativeStringFields(tls, "serverName", "fingerprint", "publicKey", "shortId", "spiderX"); err != nil {
		return nil, err
	}
	if alpn, exists := tls["alpn"]; exists {
		values, ok := alpn.([]any)
		if !ok {
			return nil, nativeUnsupported("ALPN")
		}
		for _, value := range values {
			if _, ok := value.(string); !ok {
				return nil, nativeUnsupported("ALPN")
			}
		}
	}
	if security == "tls" {
		if err = nativeKeys(tls, "serverName", "fingerprint", "alpn", "allowInsecure"); err != nil {
			return nil, err
		}
		if tls["allowInsecure"] != nil {
			if _, ok := tls["allowInsecure"].(bool); !ok {
				return nil, nativeUnsupported("allowInsecure")
			}
		}
	} else if security == "reality" {
		if err = nativeKeys(tls, "serverName", "fingerprint", "publicKey", "shortId", "spiderX"); err != nil {
			return nil, err
		}
		// The root path is the default Xray crawler hint after failed Reality
		// authentication; it does not alter a verified handshake. Native cores
		// still enforce the supplied SNI, public key and short ID themselves.
		if spider := str(tls["spiderX"]); spider != "" && spider != "/" {
			return nil, nativeUnsupported("Reality spiderX")
		}
		if str(tls["serverName"]) == "" || str(tls["publicKey"]) == "" {
			return nil, nativeUnsupported("Reality SNI/public key")
		}
		if protocol != "vless" {
			return nil, nativeUnsupported("Reality требует VLESS")
		}
	}
	if protocol == "shadowsocks" && (network != "tcp" || security != "none") {
		return nil, nativeUnsupported("Shadowsocks с дополнительным транспортом/TLS")
	}
	if protocol == "vless" && str(user["flow"]) != "" && (network != "tcp" || security == "none") {
		return nil, nativeUnsupported("Vision требует TCP и TLS/Reality")
	}
	if protocol == "shadowsocks" {
		switch str(endpoint["method"]) {
		case "aes-128-gcm", "aes-256-gcm", "chacha20-poly1305", "chacha20-ietf-poly1305", "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305":
		default:
			return nil, nativeUnsupported("Shadowsocks cipher")
		}
	}
	if id == "sing-box" {
		return nativeSingBox(protocol, endpoint, user, network, security, transport, tls, sp, hp)
	}
	return nativeMihomo(protocol, endpoint, user, network, security, transport, tls, sp, hp)
}

func nativeSingBox(protocol string, endpoint, user object, network, security string, transport, tls object, sp, hp int) ([]byte, error) {
	proxy := object{"type": protocol, "tag": "proxy", "server": endpoint["address"], "server_port": endpoint["port"]}
	switch protocol {
	case "vless":
		proxy["uuid"] = user["id"]
		if flow := str(user["flow"]); flow != "" {
			proxy["flow"] = flow
		}
	case "vmess":
		proxy["uuid"] = user["id"]
		proxy["security"] = defaultString(str(user["security"]), "auto")
	case "trojan":
		proxy["password"] = endpoint["password"]
	case "shadowsocks":
		proxy["password"] = endpoint["password"]
		method := str(endpoint["method"])
		if method == "chacha20-poly1305" {
			method = "chacha20-ietf-poly1305"
		}
		proxy["method"] = method
	}
	if network == "ws" {
		proxy["transport"] = object{"type": "ws", "path": defaultString(str(transport["path"]), "/"), "headers": obj(transport["headers"])}
	}
	if network == "grpc" {
		proxy["transport"] = object{"type": "grpc", "service_name": defaultString(str(transport["serviceName"]), "")}
	}
	if security != "none" {
		t := object{"enabled": true}
		if sni := str(tls["serverName"]); sni != "" {
			t["server_name"] = sni
		}
		if security == "tls" {
			if tls["allowInsecure"] != nil {
				t["insecure"] = tls["allowInsecure"]
			}
			if tls["alpn"] != nil {
				t["alpn"] = tls["alpn"]
			}
		}
		if fp := str(tls["fingerprint"]); fp != "" {
			t["utls"] = object{"enabled": true, "fingerprint": fp}
		}
		if security == "reality" {
			t["reality"] = object{"enabled": true, "public_key": tls["publicKey"], "short_id": defaultString(str(tls["shortId"]), "")}
		}
		proxy["tls"] = t
	}
	config := object{"log": object{"level": "warn"}, "inbounds": []any{object{"type": "socks", "tag": "socks-in", "listen": "127.0.0.1", "listen_port": sp}, object{"type": "http", "tag": "http-in", "listen": "127.0.0.1", "listen_port": hp}}, "outbounds": []any{proxy, object{"type": "direct", "tag": "direct"}}, "route": object{"final": "proxy"}}
	return json.MarshalIndent(config, "", "  ")
}
func nativeMihomo(protocol string, endpoint, user object, network, security string, transport, tls object, sp, hp int) ([]byte, error) {
	kind := protocol
	if kind == "shadowsocks" {
		kind = "ss"
	}
	proxy := object{"name": "proxy", "type": kind, "server": endpoint["address"], "port": endpoint["port"], "udp": false}
	switch protocol {
	case "vless":
		proxy["uuid"] = user["id"]
		if flow := str(user["flow"]); flow != "" {
			proxy["flow"] = flow
		}
	case "vmess":
		proxy["uuid"] = user["id"]
		proxy["alterId"] = 0
		proxy["cipher"] = defaultString(str(user["security"]), "auto")
	case "trojan":
		proxy["password"] = endpoint["password"]
	case "shadowsocks":
		proxy["password"] = endpoint["password"]
		method := str(endpoint["method"])
		if method == "chacha20-poly1305" {
			method = "chacha20-ietf-poly1305"
		}
		proxy["cipher"] = method
	}
	if network != "tcp" {
		proxy["network"] = network
	}
	if network == "ws" {
		proxy["ws-opts"] = object{"path": defaultString(str(transport["path"]), "/"), "headers": obj(transport["headers"])}
	}
	if network == "grpc" {
		proxy["grpc-opts"] = object{"grpc-service-name": defaultString(str(transport["serviceName"]), "")}
	}
	if security != "none" {
		if protocol != "trojan" {
			proxy["tls"] = true
		}
		sniKey := "servername"
		if protocol == "trojan" {
			sniKey = "sni"
		}
		if sni := str(tls["serverName"]); sni != "" {
			proxy[sniKey] = sni
		}
		if security == "tls" {
			if tls["allowInsecure"] != nil {
				proxy["skip-cert-verify"] = tls["allowInsecure"]
			}
			if tls["alpn"] != nil {
				proxy["alpn"] = tls["alpn"]
			}
		}
		if fp := str(tls["fingerprint"]); fp != "" {
			proxy["client-fingerprint"] = fp
		}
		if security == "reality" {
			proxy["reality-opts"] = object{"public-key": tls["publicKey"], "short-id": defaultString(str(tls["shortId"]), "")}
		}
	} else if protocol == "trojan" {
		return nil, nativeUnsupported("Mihomo Trojan без TLS")
	}
	config := object{"port": hp, "socks-port": sp, "allow-lan": false, "bind-address": "127.0.0.1", "mode": "rule", "find-process-mode": "off", "log-level": "warning", "dns": object{"enable": false}, "proxies": []any{proxy}, "rules": []string{"MATCH,proxy"}}
	return json.MarshalIndent(config, "", "  ")
}

// Keep error text useful without including provider credentials.
func coreName(id string) string {
	switch id {
	case "", "xray":
		return "Xray"
	case "sing-box":
		return "sing-box"
	case "mihomo":
		return "Mihomo"
	}
	return "ядро"
}
