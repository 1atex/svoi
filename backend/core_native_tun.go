package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
)

const nativeTunIPv4 = "172.31.254.1/30"
const nativeTunIPv6 = "fd42:7376:6f69:2::1/126"

// Overlay only an already validated LOCAL runtime configuration. Constructing
// and checking this JSON never creates an adapter or modifies host networking.
// The caller owns Windows permission checks, process lifecycle and readiness.
func nativeWindowsTunConfig(core string, rawJSON []byte) ([]byte, error) {
	if core != "sing-box" && core != "mihomo" {
		return nil, fail(422, "Нативный TUN не поддерживается этим ядром")
	}
	var config object
	if json.Unmarshal(rawJSON, &config) != nil || config == nil {
		return nil, fail(422, "Неверная локальная конфигурация для TUN")
	}
	var nonce [4]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return nil, err
	}
	prefix := "SVOI-SB-"
	if core == "mihomo" {
		prefix = "SVOI-MH-"
	}
	name := prefix + hex.EncodeToString(nonce[:])
	if core == "sing-box" {
		inbounds, err := providerObjects(config["inbounds"], "inbounds", false)
		if err != nil {
			return nil, err
		}
		used := map[string]bool{}
		for _, inbound := range inbounds {
			if inbound["type"] == "tun" {
				return nil, fail(422, "Локальная конфигурация уже содержит TUN")
			}
			used[str(inbound["tag"])] = true
		}
		tag := "svoi-native-tun"
		for used[tag] {
			tag += "-x"
		}
		values, _ := config["inbounds"].([]any)
		config["inbounds"] = append(values, object{"type": "tun", "tag": tag, "interface_name": name, "address": []string{nativeTunIPv4, nativeTunIPv6}, "mtu": 1500, "auto_route": true, "strict_route": true, "stack": "mixed", "dns_mode": "hijack"})
		route := obj(config["route"])
		if route == nil {
			route = object{}
			config["route"] = route
		}
		// All core-created outbound sockets must bypass the new default route.
		route["auto_detect_interface"] = true
		if config["dns"] == nil {
			// Match SVOI's existing default upstreams. Typed DNS uses direct
			// transport; interface auto-detection prevents a DNS/TUN loop.
			config["dns"] = object{"servers": []any{object{"type": "udp", "tag": "svoi-tun-dns", "server": "1.1.1.1"}, object{"type": "udp", "tag": "svoi-tun-dns-fallback", "server": "8.8.8.8"}}, "final": "svoi-tun-dns"}
			if route["default_domain_resolver"] == nil {
				route["default_domain_resolver"] = "svoi-tun-dns"
			}
		}
		// The final sing-box started message is info, after PostStart. An
		// inbound listening line alone must not be treated as TUN readiness.
		log := obj(config["log"])
		if log == nil {
			log = object{}
			config["log"] = log
		}
		log["level"] = "info"
	} else {
		if obj(config["tun"])["enable"] == true {
			return nil, fail(422, "Локальная конфигурация уже содержит TUN")
		}
		config["tun"] = object{"enable": true, "device": name, "stack": "mixed", "mtu": 1500, "auto-route": true, "auto-detect-interface": true, "strict-route": true, "dns-mode": "hijack", "dns-hijack": []string{"any:53", "tcp://any:53"}, "inet6-address": []string{nativeTunIPv6}}
		// v1.19.33 RawTun has no inet4-address field. parseTun derives its
		// IPv4 /30 from DNS fake-ip-range (or 198.18.0.1 when absent). Do not
		// pretend an ignored inet4-address works or change provider FakeIP.
		dns := obj(config["dns"])
		if dns == nil {
			dns = object{}
			config["dns"] = dns
		}
		dns["enable"] = true
		if values, exists := dns["nameserver"]; !exists || emptyNativeDNSList(values) {
			dns["nameserver"] = []string{"1.1.1.1", "8.8.8.8"}
		}
		if _, exists := dns["enhanced-mode"]; !exists {
			dns["enhanced-mode"] = "redir-host"
		}
		if dns["respect-rules"] == true {
			if values, exists := dns["proxy-server-nameserver"]; !exists || emptyNativeDNSList(values) {
				dns["proxy-server-nameserver"] = []string{"1.1.1.1", "8.8.8.8"}
			}
		}
		// Positive TUN adapter logs are info; post-up alone cannot prove that
		// ReCreateTun succeeded because Mihomo also continues after errors.
		config["log-level"] = "info"
	}
	return json.MarshalIndent(config, "", "  ")
}

func emptyNativeDNSList(value any) bool {
	switch value := value.(type) {
	case []any:
		return len(value) == 0
	case []string:
		return len(value) == 0
	}
	return false
}
