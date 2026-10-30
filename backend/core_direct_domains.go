package main

import (
	"encoding/json"
	"strings"
)

// Apply application exceptions after translating/validating the provider graph.
// This keeps the same domain syntax and subdomain behavior as the Xray path.
func applyNativeDirectDomains(id string, config object, values []string) error {
	domains, err := normalizeDirectDomains(values)
	if err != nil || len(domains) == 0 {
		return err
	}
	switch id {
	case "sing-box":
		used := map[string]bool{}
		outbounds, _ := config["outbounds"].([]any)
		for _, outbound := range outbounds {
			used[str(obj(outbound)["tag"])] = true
		}
		tag := "svoi-sites-direct"
		for used[tag] {
			tag += "-x"
		}
		// Use an independent plain direct outbound, never a provider's direct
		// outbound that might have a detour or endpoint override of its own.
		config["outbounds"] = append(outbounds, object{"type": "direct", "tag": tag})
		route := obj(config["route"])
		if route == nil {
			route = object{}
			config["route"] = route
		}
		rules, _ := route["rules"].([]any)
		route["rules"] = append([]any{object{"domain_suffix": domains, "action": "route", "outbound": tag}}, rules...)
	case "mihomo":
		// DIRECT is reserved by Mihomo; user proxies/groups cannot shadow it.
		prefix := make([]any, 0, len(domains)+1)
		for _, domain := range domains {
			prefix = append(prefix, "DOMAIN-SUFFIX,"+domain+",DIRECT")
		}
		var rules []any
		switch source := config["rules"].(type) {
		case []any:
			rules = source
		case []string:
			for _, rule := range source {
				rules = append(rules, rule)
			}
		}
		if strings.EqualFold(str(config["mode"]), "global") {
			// Global mode ignores provider rules. Keep that behavior for all
			// non-exempt traffic, retaining the original rules after this match.
			prefix = append(prefix, "MATCH,GLOBAL")
			config["mode"] = "rule"
		}
		config["rules"] = append(prefix, rules...)
	default:
		return nativeUnsupported("ядро для сайтов напрямую")
	}
	return nil
}

func nativeConfigWithDirectDomains(id string, raw []byte, values []string) ([]byte, error) {
	if len(values) == 0 {
		return raw, nil
	}
	var config object
	if err := json.Unmarshal(raw, &config); err != nil {
		return nil, err
	}
	if err := applyNativeDirectDomains(id, config, values); err != nil {
		return nil, err
	}
	return json.MarshalIndent(config, "", "  ")
}
