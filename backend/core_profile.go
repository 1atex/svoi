package main

import (
	"encoding/json"
	"fmt"
	"net/netip"
	"regexp"
	"strconv"
	"strings"
)

// Full-profile support is deliberately bounded. The source graph is validated
// before translation: unsupported DNS, routing, inbound or outbound semantics
// must never turn into a working-looking profile with different traffic paths.
func buildNativeProfileConfig(id string, server ServerConfig, sp, hp int, mode string) ([]byte, error) {
	if (id != "sing-box" && id != "mihomo") || (mode != "local" && mode != "system") {
		return nil, nativeUnsupported("режим полного профиля")
	}
	if len(server.Profile) == 0 || len(server.Profile) > 2<<20 {
		return nil, nativeUnsupported("пустой или слишком большой полный профиль")
	}
	if server.RuntimeApps != nil && server.RuntimeApps.Mode != "" && server.RuntimeApps.Mode != "all" {
		return nil, nativeUnsupported("пользовательская маршрутизация полного профиля")
	}
	var profile object
	if json.Unmarshal(server.Profile, &profile) != nil || profile == nil {
		return nil, nativeUnsupported("неверный JSON полного профиля")
	}
	if err := nativeKeys(profile, "remarks", "log", "inbounds", "outbounds", "routing"); err != nil {
		return nil, err
	}
	if err := nativeStringFields(profile, "remarks"); err != nil {
		return nil, err
	}
	if err := nativeProfileInbounds(profile); err != nil {
		return nil, err
	}
	if value, exists := profile["log"]; exists {
		log, ok := value.(map[string]any)
		if !ok {
			return nil, nativeUnsupported("log полного профиля")
		}
		if err := nativeKeys(log, "loglevel"); err != nil {
			return nil, err
		}
		// Match buildProfileConfig: SVOI replaces provider logging with warning
		// level when creating its local runtime, regardless of the source level.
		if value, exists := log["loglevel"]; exists {
			level, ok := value.(string)
			if !ok {
				return nil, nativeUnsupported("тип log.loglevel")
			}
			switch level {
			case "", "debug", "info", "warning", "error", "none":
			default:
				return nil, nativeUnsupported("log.loglevel")
			}
		}
	}
	config := nativeProfileBase(id, sp, hp)
	outs, ok := profile["outbounds"].([]any)
	if !ok || len(outs) == 0 || len(outs) > 64 {
		return nil, nativeUnsupported("список outbounds полного профиля")
	}
	targets := make(map[string]nativeProfileTarget)
	var first nativeProfileTarget
	converted := []any{}
	for index, value := range outs {
		out, ok := value.(map[string]any)
		if !ok {
			return nil, nativeUnsupported("outbounds содержит не объект")
		}
		if err := nativeStringFields(out, "tag", "protocol"); err != nil {
			return nil, err
		}
		tag := str(out["tag"])
		if _, exists := targets[tag]; tag != "" && exists {
			return nil, nativeUnsupported("повторяющиеся теги outbounds")
		}
		target := nativeProfileTarget{name: fmt.Sprintf("svoi-node-%d", index)}
		switch str(out["protocol"]) {
		case "freedom", "blackhole":
			if err := nativeProfileService(out); err != nil {
				return nil, err
			}
			target.block = out["protocol"] == "blackhole"
			if id == "mihomo" {
				target.name = "DIRECT"
				if target.block {
					target.name = "REJECT"
				}
			} else if !target.block {
				converted = append(converted, object{"type": "direct", "tag": target.name})
			}
		default:
			node := server
			node.FullProfile, node.Profile = false, nil
			node.RuntimeDirectDomains = nil
			node.Outbound, _ = json.Marshal(out)
			raw, err := buildNativeCoreConfig(id, node, sp, hp, mode)
			if err != nil {
				return nil, err
			}
			var standalone object
			if json.Unmarshal(raw, &standalone) != nil {
				return nil, nativeUnsupported("преобразование outbound")
			}
			// Mihomo's custom CA pool is global, unlike Xray's per-outbound trust.
			// Merging it would weaken certificate verification on other nodes.
			if id == "mihomo" && standalone["tls"] != nil {
				return nil, nativeUnsupported("глобальные корневые сертификаты TLS в полном профиле Mihomo")
			}
			key, nameKey := "outbounds", "tag"
			if id == "mihomo" {
				key, nameKey = "proxies", "name"
			}
			items, ok := standalone[key].([]any)
			if !ok || len(items) == 0 {
				return nil, nativeUnsupported("преобразование outbound")
			}
			proxy := obj(items[0])
			proxy[nameKey] = target.name
			// Xray proxy outbounds carry UDP too. Leaving Mihomo's conservative
			// standalone udp:false would let its router fall through to another rule.
			if id == "mihomo" {
				proxy["udp"] = true
			}
			converted = append(converted, proxy)
		}
		if index == 0 {
			first = target
		}
		if tag != "" {
			targets[tag] = target
		}
	}
	routing := object{}
	if value, exists := profile["routing"]; exists {
		var ok bool
		routing, ok = value.(map[string]any)
		if !ok {
			return nil, nativeUnsupported("тип routing")
		}
	}
	if err := nativeKeys(routing, "domainStrategy", "rules"); err != nil {
		return nil, err
	}
	if value, exists := routing["domainStrategy"]; exists && value != "AsIs" && value != "" {
		return nil, nativeUnsupported("routing.domainStrategy: поддерживается только AsIs")
	}
	rules := []any{}
	if value, exists := routing["rules"]; exists {
		var ok bool
		rules, ok = value.([]any)
		if !ok || len(rules) > 256 {
			return nil, nativeUnsupported("список routing.rules")
		}
	}
	singRules, mihomoRules := []any{}, []string{}
	for _, value := range rules {
		rule, ok := value.(map[string]any)
		if !ok {
			return nil, nativeUnsupported("routing.rules содержит не объект")
		}
		conditions, err := nativeProfileRule(rule)
		if err != nil {
			return nil, err
		}
		tag, ok := rule["outboundTag"].(string)
		target, exists := targets[tag]
		if !ok || tag == "" || !exists {
			return nil, nativeUnsupported("routing.rules ссылается на отсутствующий outbound")
		}
		if id == "sing-box" {
			singRules = append(singRules, nativeProfileSingRule(conditions, target))
		} else {
			mihomoRules = append(mihomoRules, nativeProfileMihomoRule(conditions, target))
		}
	}
	if id == "sing-box" {
		// Reject is a route action in current sing-box, not a removed block outbound.
		if first.block {
			singRules = append(singRules, nativeProfileSingRule(nil, first))
		}
		if len(converted) == 0 {
			converted = append(converted, object{"type": "direct", "tag": "svoi-unused-direct"})
		}
		config["outbounds"] = converted
		route := object{"rules": singRules}
		if !first.block {
			route["final"] = first.name
		}
		config["route"] = route
	} else {
		config["proxies"] = converted
		config["rules"] = append(mihomoRules, "MATCH,"+first.name)
	}
	if err := applyNativeDirectDomains(id, config, server.RuntimeDirectDomains); err != nil {
		return nil, err
	}
	return json.MarshalIndent(config, "", "  ")
}

type nativeProfileTarget struct {
	name  string
	block bool
}
type nativeProfileCondition struct {
	sing   object
	mihomo string
}

func nativeProfileBase(id string, sp, hp int) object {
	if id == "mihomo" {
		return object{"port": hp, "socks-port": sp, "allow-lan": false, "bind-address": "127.0.0.1", "mode": "rule", "find-process-mode": "off", "log-level": "warning", "dns": object{"enable": false}}
	}
	return object{"log": object{"level": "warn"}, "inbounds": []any{object{"type": "socks", "tag": "socks-in", "listen": "127.0.0.1", "listen_port": sp}, object{"type": "http", "tag": "http-in", "listen": "127.0.0.1", "listen_port": hp}}}
}

func nativeProfileInbounds(profile object) error {
	value, exists := profile["inbounds"]
	if !exists {
		return nil
	}
	inbounds, ok := value.([]any)
	if !ok || len(inbounds) > 2 {
		return nativeUnsupported("inbounds полного профиля")
	}
	seen := map[string]bool{}
	for _, value := range inbounds {
		in, ok := value.(map[string]any)
		if !ok {
			return nativeUnsupported("inbounds содержит не объект")
		}
		if err := nativeKeys(in, "tag", "protocol", "listen", "port", "settings", "sniffing"); err != nil {
			return err
		}
		protocol := str(in["protocol"])
		if (protocol != "socks" && protocol != "http") || seen[protocol] {
			return nativeUnsupported("тип или повторение входа полного профиля")
		}
		seen[protocol] = true
		if err := nativeStringFields(in, "tag", "protocol", "listen"); err != nil {
			return err
		}
		if value, exists := in["sniffing"]; exists {
			sniff, ok := value.(map[string]any)
			if !ok || len(sniff) != 1 || sniff["enabled"] != false {
				return nativeUnsupported("sniffing полного профиля")
			}
		}
		if value, exists := in["settings"]; exists {
			settings, ok := value.(map[string]any)
			if !ok {
				return nativeUnsupported("settings входа полного профиля")
			}
			if protocol == "http" && len(settings) != 0 {
				return nativeUnsupported("настройки HTTP входа полного профиля")
			}
			if err := nativeKeys(settings, "auth", "udp"); err != nil {
				return err
			}
			if value, exists := settings["auth"]; exists && value != "noauth" {
				return nativeUnsupported("аутентификация входа полного профиля")
			}
			if value, exists := settings["udp"]; exists && value != true {
				return nativeUnsupported("UDP входа полного профиля")
			}
		}
	}
	return nil
}

func nativeProfileService(out object) error {
	if err := nativeKeys(out, "protocol", "tag", "settings"); err != nil {
		return err
	}
	settings := object{}
	if value, exists := out["settings"]; exists {
		var ok bool
		settings, ok = value.(map[string]any)
		if !ok {
			return nativeUnsupported("settings служебного outbound")
		}
	}
	if out["protocol"] == "freedom" {
		if err := nativeKeys(settings, "domainStrategy"); err != nil {
			return err
		}
		if value, exists := settings["domainStrategy"]; exists && value != "AsIs" && value != "" {
			return nativeUnsupported("freedom.domainStrategy")
		}
		return nil
	}
	if err := nativeKeys(settings, "response"); err != nil {
		return err
	}
	if value, exists := settings["response"]; exists {
		response, ok := value.(map[string]any)
		if !ok {
			return nativeUnsupported("blackhole.response")
		}
		if err := nativeKeys(response, "type"); err != nil {
			return err
		}
		if value, exists := response["type"]; exists && value != "none" && value != "" {
			return nativeUnsupported("blackhole.response")
		}
	}
	return nil
}

var nativeProfileDomainRE = regexp.MustCompile(`^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*$`)

func nativeProfileStrings(value any, label string) ([]string, error) {
	values, ok := value.([]any)
	if !ok || len(values) == 0 || len(values) > 128 {
		return nil, nativeUnsupported("список " + label)
	}
	result := []string{}
	for _, value := range values {
		text, ok := value.(string)
		if !ok || text == "" {
			return nil, nativeUnsupported("значение " + label)
		}
		result = append(result, text)
	}
	return result, nil
}

func nativeProfileRule(rule object) ([]nativeProfileCondition, error) {
	if err := nativeKeys(rule, "type", "domain", "ip", "network", "port", "outboundTag", "ruleTag"); err != nil {
		return nil, err
	}
	if value, exists := rule["type"]; exists && value != "field" {
		return nil, nativeUnsupported("тип routing.rules")
	}
	if err := nativeStringFields(rule, "ruleTag"); err != nil {
		return nil, err
	}
	conditions := []nativeProfileCondition{}
	for _, field := range []string{"domain", "ip"} {
		if value, exists := rule[field]; exists {
			values, err := nativeProfileStrings(value, field)
			if err != nil {
				return nil, err
			}
			choices := []nativeProfileCondition{}
			for _, value := range values {
				if field == "domain" {
					kind, text := "domain_keyword", value
					mihomoKind := "DOMAIN-KEYWORD"
					if prefix, rest, found := strings.Cut(value, ":"); found {
						text = rest
						switch prefix {
						case "full":
							kind, mihomoKind = "domain", "DOMAIN"
						case "domain":
							kind, mihomoKind = "domain_suffix", "DOMAIN-SUFFIX"
						case "keyword":
						default:
							return nil, nativeUnsupported("селектор domain: поддерживаются full/domain/keyword")
						}
					}
					if !nativeProfileDomainRE.MatchString(text) {
						return nil, nativeUnsupported("значение domain")
					}
					text = strings.ToLower(text)
					choices = append(choices, nativeProfileCondition{object{kind: []string{text}}, mihomoKind + "," + text})
				} else {
					prefix, err := netip.ParsePrefix(value)
					if err != nil {
						addr, e := netip.ParseAddr(value)
						if e != nil {
							return nil, nativeUnsupported("ip: требуется адрес или CIDR без geoip")
						}
						prefix = netip.PrefixFrom(addr, addr.BitLen())
					}
					if prefix.Addr().Is4In6() {
						return nil, nativeUnsupported("IPv4-mapped IPv6 в ip")
					}
					cidr := prefix.Masked().String()
					choices = append(choices, nativeProfileCondition{object{"ip_cidr": []string{cidr}}, "IP-CIDR," + cidr + ",no-resolve"})
				}
			}
			condition := nativeProfileCombine(choices, "or")
			if field == "ip" {
				// Mihomo resolves its default hosts (including localhost) before
				// evaluating rules, even with no-resolve. Xray AsIs matches IP
				// predicates only for an IP destination when sniffing is disabled.
				// Mihomo fixMetadata clears Host on literal IPs, so exclude every
				// nonempty hostname before examining destination IP metadata.
				condition.mihomo = "AND,((NOT,((DOMAIN-REGEX,.+))),(" + condition.mihomo + "))"
			}
			conditions = append(conditions, condition)
		}
	}
	if value, exists := rule["network"]; exists {
		text, ok := value.(string)
		if !ok {
			return nil, nativeUnsupported("тип network")
		}
		choices := []nativeProfileCondition{}
		for _, network := range strings.Split(text, ",") {
			if network != "tcp" && network != "udp" {
				return nil, nativeUnsupported("network: поддерживаются tcp/udp")
			}
			choices = append(choices, nativeProfileCondition{object{"network": []string{network}}, "NETWORK," + strings.ToUpper(network)})
		}
		if len(choices) > 2 {
			return nil, nativeUnsupported("network")
		}
		conditions = append(conditions, nativeProfileCombine(choices, "or"))
	}
	if value, exists := rule["port"]; exists {
		text, ok := value.(string)
		if !ok {
			if n, valid := value.(float64); valid && n == float64(int(n)) {
				text = strconv.Itoa(int(n))
			} else {
				return nil, nativeUnsupported("тип port")
			}
		}
		ports := strings.Split(text, ",")
		if len(ports) > 128 {
			return nil, nativeUnsupported("список port")
		}
		choices := []nativeProfileCondition{}
		for _, port := range ports {
			low, high, rangePort := strings.Cut(port, "-")
			a, err := strconv.Atoi(low)
			if err != nil || a < 1 || a > 65535 {
				return nil, nativeUnsupported("значение port")
			}
			condition := object{"port": []int{a}}
			if rangePort {
				b, err := strconv.Atoi(high)
				if err != nil || b < a || b > 65535 {
					return nil, nativeUnsupported("диапазон port")
				}
				condition = object{"port_range": []string{fmt.Sprintf("%d:%d", a, b)}}
			}
			choices = append(choices, nativeProfileCondition{condition, "DST-PORT," + port})
		}
		conditions = append(conditions, nativeProfileCombine(choices, "or"))
	}
	if len(conditions) == 0 {
		return nil, nativeUnsupported("routing.rules без условий")
	}
	return conditions, nil
}

func nativeProfileCombine(conditions []nativeProfileCondition, mode string) nativeProfileCondition {
	if len(conditions) == 1 {
		return conditions[0]
	}
	rules, parts := []any{}, []string{}
	for _, condition := range conditions {
		rules = append(rules, condition.sing)
		parts = append(parts, "("+condition.mihomo+")")
	}
	return nativeProfileCondition{object{"type": "logical", "mode": mode, "rules": rules}, strings.ToUpper(mode) + ",(" + strings.Join(parts, ",") + ")"}
}
func nativeProfileSingRule(conditions []nativeProfileCondition, target nativeProfileTarget) object {
	rule := object{}
	if len(conditions) > 0 {
		rule = nativeProfileCombine(conditions, "and").sing
	}
	if target.block {
		rule["action"], rule["method"] = "reject", "drop"
	} else {
		rule["action"], rule["outbound"] = "route", target.name
	}
	return rule
}
func nativeProfileMihomoRule(conditions []nativeProfileCondition, target nativeProfileTarget) string {
	if len(conditions) == 0 {
		return "MATCH," + target.name
	}
	condition := nativeProfileCombine(conditions, "and").mihomo
	// Ordinary IP rules put no-resolve after the target; logical child rules
	// retain it as a child parameter, as required by Mihomo's logical parser.
	if strings.HasPrefix(condition, "IP-CIDR,") && strings.HasSuffix(condition, ",no-resolve") {
		return strings.TrimSuffix(condition, ",no-resolve") + "," + target.name + ",no-resolve"
	}
	return condition + "," + target.name
}
