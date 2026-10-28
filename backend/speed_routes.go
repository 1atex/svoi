package main

import (
	"encoding/json"
	"strings"
)

func speedServerConfig(server ServerConfig) (ServerConfig, error) {
	server.RuntimeApps = nil
	server.RuntimeDirectDomains = nil
	if len(server.Profile) == 0 {
		return server, nil
	}
	var config object
	if err := json.Unmarshal(server.Profile, &config); err != nil {
		return server, err
	}
	routing := obj(config["routing"])
	if routing == nil {
		routing = object{}
		config["routing"] = routing
	}
	if str(routing["script"]) != "" {
		return server, fail(422, "Для интернетометра нужен профиль без routing.script. Выберите отдельный сервер.")
	}
	outbounds, _ := config["outbounds"].([]any)
	used := map[string]bool{}
	originalInbounds, _ := config["inbounds"].([]any)
	for _, v := range originalInbounds {
		used[str(obj(v)["tag"])] = true
	}
	for _, v := range outbounds {
		used[str(obj(v)["tag"])] = true
	}
	unique := func(tag string) string {
		for used[tag] {
			tag += "-x"
		}
		used[tag] = true
		return tag
	}
	proxies := []string{}
	for _, v := range outbounds {
		out := obj(v)
		if serviceOutbound(str(out["protocol"])) {
			continue
		}
		tag := str(out["tag"])
		if tag == "" {
			tag = unique("svoi-speed-proxy")
			out["tag"] = tag
		}
		proxies = append(proxies, tag)
	}
	if len(proxies) == 0 {
		return server, fail(422, "В профиле не найден VPN-выход для замера")
	}
	inbounds, _ := config["inbounds"].([]any)
	httpTag := ""
	for _, v := range inbounds {
		in := obj(v)
		if str(in["protocol"]) == "http" {
			httpTag = str(in["tag"])
			if httpTag == "" {
				httpTag = unique("svoi-speed-http")
				in["tag"] = httpTag
			}
		}
	}
	if httpTag == "" {
		httpTag = unique("svoi-speed-http")
		inbounds = append(inbounds, object{"tag": httpTag, "protocol": "http"})
		config["inbounds"] = inbounds
	}
	rule := object{"type": "field", "inboundTag": []string{httpTag}, "outboundTag": proxies[0]}
	balancers, _ := routing["balancers"].([]any)
	for _, raw := range balancers {
		bal := obj(raw)
		if str(bal["tag"]) == "" {
			continue
		}
		selectors, _ := bal["selector"].([]any)
		matches := []any{}
		for _, tag := range proxies {
			for _, prefix := range selectors {
				if str(prefix) != "" && strings.HasPrefix(tag, str(prefix)) {
					matches = append(matches, tag)
					break
				}
			}
		}
		if len(matches) == 0 {
			continue
		}
		bal["selector"] = matches
		bal["fallbackTag"] = matches[0]
		delete(rule, "outboundTag")
		rule["balancerTag"] = str(bal["tag"])
		break
	}
	rules, _ := routing["rules"].([]any)
	routing["rules"] = append([]any{rule}, rules...)
	data, err := json.Marshal(config)
	server.Profile = data
	return server, err
}
