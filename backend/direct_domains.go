package main

import (
	"net"
	"strings"
)

func normalizeDirectDomains(values []string) ([]string, error) {
	if len(values) > 64 {
		return nil, fail(400, "Можно добавить до 64 сайтов напрямую")
	}
	result := []string{}
	seen := map[string]bool{}
	for _, raw := range values {
		domain := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(raw), "."))
		domain = strings.TrimPrefix(domain, "*.")
		if len(domain) > 253 || !strings.Contains(domain, ".") || net.ParseIP(domain) != nil {
			return nil, fail(400, "Укажите домен сайта, например yandex.ru, без пути и номера порта")
		}
		for _, label := range strings.Split(domain, ".") {
			if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
				return nil, fail(400, "Неверный домен сайта")
			}
			for _, char := range label {
				if !(char >= 'a' && char <= 'z' || char >= '0' && char <= '9' || char == '-') {
					return nil, fail(400, "Для международного домена используйте его запись xn-- (punycode)")
				}
			}
		}
		if !seen[domain] {
			result = append(result, domain)
			seen[domain] = true
		}
	}
	return result, nil
}

func applyDirectDomains(config object, domains []string) error {
	domains, err := normalizeDirectDomains(domains)
	if err != nil || len(domains) == 0 {
		return err
	}
	routing := obj(config["routing"])
	if routing == nil {
		routing = object{}
		config["routing"] = routing
	}
	if str(routing["script"]) != "" {
		return fail(422, "Сайты напрямую несовместимы с routing.script этого профиля")
	}
	used := map[string]bool{}
	outbounds, _ := config["outbounds"].([]any)
	for _, out := range outbounds {
		used[str(obj(out)["tag"])] = true
	}
	tag := "svoi-sites-direct"
	for used[tag] {
		tag += "-x"
	}
	config["outbounds"] = append(outbounds, object{"tag": tag, "protocol": "freedom", "settings": object{"domainStrategy": "UseIP"}})
	selectors := []string{}
	for _, domain := range domains {
		selectors = append(selectors, "domain:"+domain)
	}
	rules, _ := routing["rules"].([]any)
	routing["rules"] = append([]any{object{"type": "field", "domain": selectors, "outboundTag": tag, "ruleTag": "SVOI sites direct"}}, rules...)
	return nil
}
