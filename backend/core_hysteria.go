package main

import (
	"crypto/x509"
	"encoding/json"
	"strconv"
	"strings"
)

// nativeHysteriaConfig translates the parser's Xray-shaped Hysteria v2
// outbound. Unknown transport, TLS, pinning and finalmask settings are errors.
// It does not modify out or install trust anchors in the operating system.
func nativeHysteriaConfig(id string, out object, sp, hp int) ([]byte, error) {
	if id != "sing-box" && id != "mihomo" {
		return nil, nativeUnsupported("ядро Hysteria2")
	}
	if err := nativeKeys(out, "protocol", "tag", "settings", "streamSettings", "mux"); err != nil {
		return nil, err
	}
	if str(out["protocol"]) != "hysteria" {
		return nil, nativeUnsupported("ожидается Hysteria версии 2")
	}
	if err := nativeDisabledMux(out); err != nil {
		return nil, err
	}
	for _, key := range []string{"settings", "streamSettings"} {
		if err := nativeObjectField(out, key); err != nil {
			return nil, err
		}
	}
	settings, stream := obj(out["settings"]), obj(out["streamSettings"])
	if err := nativeKeys(settings, "version", "address", "port"); err != nil {
		return nil, err
	}
	if err := nativeStringFields(settings, "address"); err != nil {
		return nil, err
	}
	version, versionOK := hysteriaInteger(settings["version"])
	if !versionOK || version != 2 || str(settings["address"]) == "" {
		return nil, nativeUnsupported("адрес или версия Hysteria2")
	}
	port, portOK := hysteriaInteger(settings["port"])
	if !portOK || port < 1 || port > 65535 {
		return nil, nativeUnsupported("порт Hysteria2")
	}
	if err := nativeKeys(stream, "network", "security", "hysteriaSettings", "tlsSettings", "finalmask"); err != nil {
		return nil, err
	}
	if str(stream["network"]) != "hysteria" || str(stream["security"]) != "tls" {
		return nil, nativeUnsupported("Hysteria2 требует транспорт hysteria и TLS")
	}
	for _, key := range []string{"hysteriaSettings", "tlsSettings", "finalmask"} {
		if err := nativeObjectField(stream, key); err != nil {
			return nil, err
		}
	}
	hy, tls := obj(stream["hysteriaSettings"]), obj(stream["tlsSettings"])
	if err := nativeKeys(hy, "version", "auth"); err != nil {
		return nil, err
	}
	version, versionOK = hysteriaInteger(hy["version"])
	if !versionOK || version != 2 {
		return nil, nativeUnsupported("версия транспорта Hysteria2")
	}
	if err := nativeStringFields(hy, "auth"); err != nil {
		return nil, err
	}
	if err := nativeKeys(tls, "serverName", "alpn", "allowInsecure", "certificates", "disableSystemRoot"); err != nil {
		return nil, err
	}
	if err := nativeStringFields(tls, "serverName"); err != nil {
		return nil, err
	}
	insecure, exclusiveRoots := false, false
	for _, key := range []string{"allowInsecure", "disableSystemRoot"} {
		if value, exists := tls[key]; exists {
			b, ok := value.(bool)
			if !ok {
				return nil, nativeUnsupported("тип TLS." + key)
			}
			if key == "allowInsecure" {
				insecure = b
			} else {
				exclusiveRoots = b
			}
		}
	}
	var alpn []string
	if value, exists := tls["alpn"]; exists {
		values, err := hysteriaStringList(value)
		if err != nil {
			return nil, nativeUnsupported("ALPN Hysteria2")
		}
		if len(values) == 0 {
			return nil, nativeUnsupported("пустой ALPN Hysteria2")
		}
		alpn = values
	}
	anchors, err := hysteriaTrustAnchors(tls)
	if err != nil {
		return nil, err
	}
	if exclusiveRoots && len(anchors) == 0 {
		return nil, nativeUnsupported("disableSystemRoot без встроенного сертификата")
	}
	if len(anchors) > 0 {
		// sing-box's per-proxy certificate pool replaces roots. Preserve that
		// explicitly requested policy rather than silently restricting the pool.
		if id == "sing-box" && !exclusiveRoots {
			return nil, nativeUnsupported("sing-box: встроенный CA требует disableSystemRoot=true")
		}
		if id == "mihomo" {
			return nil, nativeUnsupported("Mihomo: встроенные CA не применяются надёжно в этой версии; требуется TLS с общедоверенным сертификатом")
		}
	}
	password, server := str(hy["auth"]), str(settings["address"])
	sni := defaultString(str(tls["serverName"]), server)
	proxy := object{"type": "hysteria2", "server": server, "password": password}
	if id == "sing-box" {
		proxy["tag"], proxy["server_port"] = "proxy", port
		tlsOut := object{"enabled": true, "server_name": sni, "insecure": insecure}
		if alpn != nil {
			tlsOut["alpn"] = alpn
		}
		if len(anchors) > 0 {
			tlsOut["certificate"] = anchors
		}
		proxy["tls"] = tlsOut
	} else {
		proxy["name"], proxy["port"], proxy["sni"], proxy["skip-cert-verify"] = "proxy", port, sni, insecure
		if alpn != nil {
			proxy["alpn"] = alpn
		}
	}
	if err := nativeHysteriaMasks(id, stream, proxy); err != nil {
		return nil, err
	}
	if id == "sing-box" {
		return json.MarshalIndent(object{"log": object{"level": "warn"}, "inbounds": []any{object{"type": "socks", "tag": "socks-in", "listen": "127.0.0.1", "listen_port": sp}, object{"type": "http", "tag": "http-in", "listen": "127.0.0.1", "listen_port": hp}}, "outbounds": []any{proxy, object{"type": "direct", "tag": "direct"}}, "route": object{"final": "proxy"}}, "", "  ")
	}
	config := object{"port": hp, "socks-port": sp, "allow-lan": false, "bind-address": "127.0.0.1", "mode": "rule", "find-process-mode": "off", "log-level": "warning", "dns": object{"enable": false}, "proxies": []any{proxy}, "rules": []string{"MATCH,proxy"}}
	return json.MarshalIndent(config, "", "  ")
}

func hysteriaStringList(value any) ([]string, error) {
	switch list := value.(type) {
	case []string:
		return append([]string(nil), list...), nil
	case []any:
		result := make([]string, len(list))
		for i, item := range list {
			s, ok := item.(string)
			if !ok {
				return nil, nativeUnsupported("ожидается список строк")
			}
			result[i] = s
		}
		return result, nil
	default:
		return nil, nativeUnsupported("ожидается список строк")
	}
}

func hysteriaInteger(value any) (int, bool) {
	switch n := value.(type) {
	case int:
		return n, true
	case float64:
		return int(n), n == float64(int(n))
	case json.Number:
		number, err := strconv.Atoi(string(n))
		return number, err == nil
	default:
		return 0, false
	}
}

func hysteriaTrustAnchors(tls object) ([]string, error) {
	value, exists := tls["certificates"]
	if !exists {
		return nil, nil
	}
	certificates, ok := value.([]any)
	if !ok || len(certificates) == 0 {
		return nil, nativeUnsupported("сертификаты Hysteria2")
	}
	anchors := []string{}
	for _, value := range certificates {
		certificate, ok := value.(map[string]any)
		if !ok {
			return nil, nativeUnsupported("сертификаты Hysteria2")
		}
		if err := nativeKeys(certificate, "certificate", "usage"); err != nil {
			return nil, err
		}
		if str(certificate["usage"]) != "verify" {
			return nil, nativeUnsupported("поддерживается только встроенный CA usage=verify")
		}
		lines, err := hysteriaStringList(certificate["certificate"])
		if err != nil {
			return nil, err
		}
		pem := strings.Join(lines, "\n")
		if !x509.NewCertPool().AppendCertsFromPEM([]byte(pem)) {
			return nil, nativeUnsupported("неверный встроенный CA Hysteria2")
		}
		anchors = append(anchors, pem)
	}
	return anchors, nil
}

func nativeHysteriaMasks(id string, stream, proxy object) error {
	value, exists := stream["finalmask"]
	if !exists {
		return nil
	}
	mask := obj(value)
	if err := nativeKeys(mask, "udp"); err != nil {
		return err
	}
	masks, ok := mask["udp"].([]any)
	if !ok || len(masks) == 0 || len(masks) > 2 {
		return nativeUnsupported("цепочка finalmask Hysteria2")
	}
	salamander, hopping := false, false
	for _, raw := range masks {
		m, ok := raw.(map[string]any)
		if !ok {
			return nativeUnsupported("маска Hysteria2")
		}
		if err := nativeKeys(m, "type", "settings"); err != nil {
			return err
		}
		if err := nativeObjectField(m, "settings"); err != nil {
			return err
		}
		settings := obj(m["settings"])
		switch str(m["type"]) {
		case "salamander":
			if salamander || hopping {
				return nativeUnsupported("порядок или повтор Salamander")
			}
			if err := nativeKeys(settings, "password"); err != nil {
				return err
			}
			if err := nativeStringFields(settings, "password"); err != nil {
				return err
			}
			password := str(settings["password"])
			if len(password) < 4 {
				return nativeUnsupported("пароль Salamander короче 4 байт")
			}
			if id == "sing-box" {
				proxy["obfs"] = object{"type": "salamander", "password": password}
			} else {
				proxy["obfs"], proxy["obfs-password"] = "salamander", password
			}
			salamander = true
		case "udphop":
			if id == "mihomo" {
				return nativeUnsupported("Mihomo меняет только удалённый порт и не сохраняет intervalLocal,intervalRemote")
			}
			if hopping {
				return nativeUnsupported("повтор port hopping")
			}
			if err := nativeKeys(settings, "mode", "interval", "remotePorts"); err != nil {
				return err
			}
			if str(settings["mode"]) != "intervalLocal,intervalRemote" {
				return nativeUnsupported("режим port hopping")
			}
			if err := nativeStringFields(settings, "remotePorts"); err != nil {
				return err
			}
			interval, validInterval := hysteriaInteger(settings["interval"])
			if !validInterval || interval < 5 || interval > 86400 {
				return nativeUnsupported("интервал port hopping")
			}
			intervalText := strconv.Itoa(interval)
			ports, _, _, err := hysteriaPorts(str(settings["remotePorts"]))
			if err != nil {
				return nativeUnsupported("диапазон port hopping")
			}
			nativePorts := strings.Split(strings.ReplaceAll(ports, "-", ":"), ",")
			for index, value := range nativePorts {
				if !strings.Contains(value, ":") {
					nativePorts[index] = value + ":" + value
				}
			}
			delete(proxy, "server_port")
			proxy["server_ports"], proxy["hop_interval"] = nativePorts, intervalText+"s"
			hopping = true
		default:
			return nativeUnsupported("маска Hysteria2")
		}
	}
	return nil
}
