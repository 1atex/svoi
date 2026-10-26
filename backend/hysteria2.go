package main

import (
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"
)

func hysteriaPorts(value string) (string, int, bool, error) {
	if len(value) > 1024 {
		return "", 0, false, errors.New("Hysteria2: слишком длинный список портов")
	}
	parts := strings.Split(value, ",")
	first, hopping := 0, len(parts) > 1
	for i, part := range parts {
		limits := strings.Split(part, "-")
		if len(limits) > 2 {
			return "", 0, false, errors.New("Hysteria2: неверный диапазон портов")
		}
		low, err := strconv.ParseUint(limits[0], 10, 16)
		if err != nil || low == 0 {
			return "", 0, false, errors.New("Hysteria2: порт должен быть от 1 до 65535")
		}
		high := low
		if len(limits) == 2 {
			high, err = strconv.ParseUint(limits[1], 10, 16)
			if err != nil || high < low {
				return "", 0, false, errors.New("Hysteria2: неверный диапазон портов")
			}
		}
		if i == 0 {
			first = int(low)
		}
		parts[i] = strconv.FormatUint(low, 10)
		if high != low {
			parts[i] += "-" + strconv.FormatUint(high, 10)
			hopping = true
		}
	}
	return strings.Join(parts, ","), first, hopping, nil
}

func parseHysteria2(raw string) (ServerConfig, error) {
	invalid := func(message string) (ServerConfig, error) { return ServerConfig{}, errors.New("Hysteria2: " + message) }
	schemeEnd := strings.Index(raw, "://")
	if schemeEnd < 0 || len(raw) > 16384 {
		return invalid("некорректная ссылка")
	}
	rest := raw[schemeEnd+3:]
	end := strings.IndexAny(rest, "/?#")
	if end < 0 {
		end = len(rest)
	}
	authority, tail := rest[:end], rest[end:]
	credentials, address := "", authority
	if at := strings.LastIndexByte(authority, '@'); at >= 0 {
		credentials, address = authority[:at+1], authority[at+1:]
	}
	host, ports := address, "443"
	if strings.HasPrefix(address, "[") {
		close := strings.IndexByte(address, ']')
		if close < 0 || net.ParseIP(address[1:close]) == nil {
			return invalid("неверный IPv6-адрес")
		}
		host = address[:close+1]
		if suffix := address[close+1:]; suffix != "" {
			if !strings.HasPrefix(suffix, ":") {
				return invalid("неверный адрес")
			}
			ports = suffix[1:]
		}
	} else if colon := strings.IndexByte(address, ':'); colon >= 0 {
		host, ports = address[:colon], address[colon+1:]
	}
	ports, port, hopping, err := hysteriaPorts(ports)
	if err != nil {
		return ServerConfig{}, err
	}
	u, err := url.Parse("hysteria2://" + credentials + host + ":" + strconv.Itoa(port) + tail)
	if err != nil || u.Hostname() == "" || (u.Path != "" && u.Path != "/") {
		return invalid("неверный адрес или путь")
	}
	q, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return invalid("неверные параметры ссылки")
	}
	for _, values := range q {
		if len(values) != 1 {
			return invalid("параметры ссылки не должны повторяться")
		}
	}
	for _, key := range []string{"insecure", "allowInsecure"} {
		if q.Has(key) {
			value, err := strconv.ParseBool(q.Get(key))
			if err != nil {
				return invalid("неверное значение " + key)
			}
			if value {
				return invalid("это ядро Xray не поддерживает отключение проверки TLS (" + key + "). Нужен сервер с проверяемым сертификатом.")
			}
		}
	}
	if q.Get("pinSHA256") != "" {
		return invalid("pinSHA256 не поддерживается этим ядром с семантикой Hysteria. Используйте проверяемый TLS-сертификат или полный профиль Xray.")
	}
	if q.Get("security") != "" && q.Get("security") != "tls" {
		return invalid("поддерживается только TLS")
	}
	if q.Has("ports") && q.Has("mport") {
		return invalid("укажите только один список ports или mport")
	}
	for _, key := range []string{"ports", "mport"} {
		if q.Has(key) {
			if hopping {
				return invalid("список портов указан и в адресе, и в параметрах")
			}
			ports, port, hopping, err = hysteriaPorts(q.Get(key))
			if err != nil {
				return ServerConfig{}, err
			}
		}
	}
	auth := ""
	if u.User != nil {
		auth = u.User.Username()
		if password, present := u.User.Password(); present {
			auth += ":" + password
		}
	}
	tls := object{"serverName": defaultString(q.Get("sni"), u.Hostname())}
	if alpn := q.Get("alpn"); alpn != "" {
		tls["alpn"] = strings.Split(alpn, ",")
	}
	if ech := q.Get("ech"); ech != "" {
		decoded, err := decodeBase64(ech)
		if err != nil {
			return invalid("неверный ECH config")
		}
		tls["echConfigList"] = base64.StdEncoding.EncodeToString(decoded)
	}
	stream := object{"network": "hysteria", "security": "tls", "tlsSettings": tls, "hysteriaSettings": object{"version": 2, "auth": auth}}
	masks := []any{}
	switch q.Get("obfs") {
	case "", "none":
		if q.Get("obfs-password") != "" {
			return invalid("пароль obfs указан без типа маскировки")
		}
	case "salamander":
		if len(q.Get("obfs-password")) < 4 {
			return invalid("пароль Salamander должен содержать минимум 4 байта")
		}
		masks = append(masks, object{"type": "salamander", "settings": object{"password": q.Get("obfs-password")}})
	default:
		return invalid("поддерживается маскировка Salamander; выбранный obfs пока не поддерживается")
	}
	if hopping {
		interval := 30
		if q.Has("hop-interval") {
			interval, err = strconv.Atoi(q.Get("hop-interval"))
			if err != nil || interval < 5 || interval > 86400 {
				return invalid("hop-interval должен быть от 5 до 86400 секунд")
			}
		}
		masks = append(masks, object{"type": "udphop", "settings": object{"mode": "intervalLocal,intervalRemote", "interval": interval, "remotePorts": ports}})
	} else if q.Has("hop-interval") {
		return invalid("hop-interval требует список или диапазон портов")
	}
	if len(masks) > 0 {
		stream["finalmask"] = object{"udp": masks}
	}
	for key := range q {
		switch key {
		case "sni", "alpn", "ech", "insecure", "allowInsecure", "security", "pinSHA256", "obfs", "obfs-password", "ports", "mport", "hop-interval":
		default:
			return invalid(fmt.Sprintf("параметр %s пока не поддерживается", metadataText(key, 40)))
		}
	}
	return serverFromOutbound(u.Fragment, object{"protocol": "hysteria", "settings": object{"version": 2, "address": u.Hostname(), "port": port}, "streamSettings": stream})
}

func isHysteriaServer(s ServerInfo) bool {
	return s.Protocol == "hysteria" || s.Protocol == "hysteria2" || s.Network == "hysteria"
}
