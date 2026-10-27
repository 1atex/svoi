package main

import (
	"fmt"
	"runtime"
)

func tunInbound(tag string) object {
	routes := []string{"0.0.0.0/0", "::/0"}
	if runtime.GOOS == "linux" {
		routes = []string{"0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"}
	}
	return object{"tag": tag, "protocol": "tun", "settings": object{
		"name": "SVOI", "desc": "SVOI", "mtu": 1500,
		"gateway":                []string{"172.31.255.1/30", "fd42:7376:6f69::1/126"},
		"dns":                    []string{"1.1.1.1", "8.8.8.8"},
		"autoSystemRoutingTable": routes,
		"autoOutboundsInterface": "auto",
	}, "sniffing": object{"enabled": true, "destOverride": []string{"http", "tls", "quic"}, "routeOnly": true}}
}

func configureTunDNS(config object, tunTag string) {
	used := map[string]bool{}
	var collect func(any)
	collect = func(v any) {
		switch x := v.(type) {
		case string:
			used[x] = true
		case []any:
			for _, v := range x {
				collect(v)
			}
		case []string:
			for _, v := range x {
				used[v] = true
			}
		case map[string]any:
			for _, v := range x {
				collect(v)
			}
		}
	}
	collect(config)
	unique := func(base string) string {
		name := base
		for i := 1; used[name]; i++ {
			name = fmt.Sprintf("%s-%d", base, i)
		}
		used[name] = true
		return name
	}
	routing := obj(config["routing"])
	if config["routing"] == nil {
		routing = object{}
		config["routing"] = routing
	}
	rules, _ := routing["rules"].([]any)
	dnsOutbounds := map[string]bool{}
	for _, raw := range config["outbounds"].([]any) {
		out := obj(raw)
		if str(out["protocol"]) == "dns" {
			dnsOutbounds[str(out["tag"])] = true
		}
	}
	dns := obj(config["dns"])
	if config["dns"] == nil {
		dns = object{"servers": []string{"1.1.1.1", "8.8.8.8"}, "queryStrategy": "UseIPv4"}
		config["dns"] = dns
	}
	if str(dns["tag"]) == "" {
		dnsTag := unique("svoi-dns-query")
		dns["tag"] = dnsTag

		for _, raw := range rules {
			rule := obj(raw)
			if dnsOutbounds[str(rule["outboundTag"])] {
				continue
			}
			tags, _ := rule["inboundTag"].([]any)
			for _, tag := range tags {
				if str(tag) == tunTag {
					rule["inboundTag"] = append(tags, dnsTag)
					break
				}
			}
		}
	}
	dnsOut := unique("svoi-dns-out")
	outbounds, _ := config["outbounds"].([]any)
	config["outbounds"] = append(outbounds, object{"tag": dnsOut, "protocol": "dns"})
	routing["rules"] = append([]any{object{"type": "field", "inboundTag": []string{tunTag}, "port": "53", "network": "tcp,udp", "outboundTag": dnsOut}}, rules...)
}
