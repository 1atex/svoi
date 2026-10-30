package main

import (
	"bytes"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"regexp"
	"strings"
)

// A provider profile remains one graph. Only the application's listeners and
// control plane are replaced; unsupported data-plane semantics fail closed.
func buildProviderNativeConfig(id string, server ServerConfig, sp, hp int, mode string) ([]byte, error) {
	if (id != "sing-box" && id != "mihomo") || server.SourceProfileCore != id {
		return nil, providerUnsupported("ядро исходного профиля не совпадает с выбранным")
	}
	if mode != "local" && mode != "system" {
		return nil, providerUnsupported("режим подключения")
	}
	if sp < 1 || sp > 65535 || hp < 1 || hp > 65535 || sp == hp {
		return nil, providerUnsupported("локальные порты")
	}
	if server.RuntimeApps != nil && server.RuntimeApps.Mode != "" && server.RuntimeApps.Mode != "all" {
		return nil, providerUnsupported("дополнительная маршрутизация приложения")
	}
	if len(server.Profile) == 0 || len(server.Profile) > nativeProviderMaxBytes {
		return nil, providerUnsupported("пустой или слишком большой профиль")
	}
	var profile object
	if json.Unmarshal(server.Profile, &profile) != nil || profile == nil {
		return nil, providerUnsupported("неверный JSON")
	}
	if err := applyProviderNodeSelection(id, profile, server.NativeTarget); err != nil {
		return nil, err
	}
	var err error
	if id == "sing-box" {
		err = providerSingBox(profile, sp, hp)
	} else {
		err = providerMihomo(profile, sp, hp)
	}
	if err != nil {
		return nil, err
	}
	if err := applyNativeDirectDomains(id, profile, server.RuntimeDirectDomains); err != nil {
		return nil, err
	}
	return json.Marshal(profile)
}

func providerUnsupported(detail string) error {
	return fail(422, "Нативный профиль провайдера не поддерживается: "+detail+". Выберите Xray: его вариант загружается при обновлении подписки.")
}

func providerKeys(m object, keys ...string) error {
	for k := range m {
		found := false
		for _, allowed := range keys {
			if k == allowed {
				found = true
				break
			}
		}
		if !found {
			return providerUnsupported("параметр " + k)
		}
	}
	return nil
}

func providerObjects(v any, label string, required bool) ([]object, error) {
	if v == nil && !required {
		return nil, nil
	}
	a, ok := v.([]any)
	if !ok || (required && len(a) == 0) {
		return nil, providerUnsupported(label + ": требуется список объектов")
	}
	result := make([]object, 0, len(a))
	for _, value := range a {
		m, ok := value.(map[string]any)
		if !ok {
			return nil, providerUnsupported(label + ": требуется объект")
		}
		result = append(result, m)
	}
	return result, nil
}

// Reject file/OS hooks at every depth, including nested TLS and transports.
// URI paths (WebSocket/HTTP) are ordinary strings and are deliberately retained.
func providerAssets(v any) error {
	switch value := v.(type) {
	case map[string]any:
		for k, child := range value {
			if strings.HasSuffix(k, "_path") || strings.HasSuffix(k, "-path") || strings.HasSuffix(k, "_file") || strings.HasSuffix(k, "-file") || k == "client_key" || k == "private_key" || k == "client_certificate" {
				return providerUnsupported("файловый ресурс " + k)
			}
			switch k {
			case "certificate_path", "certificate-path", "private_key_path", "private-key", "private-key-path", "client-certificate", "client-key", "ca", "ca-str", "certificate", "cert", "key", "ssh-private-key", "ssh-private-key-path", "identity", "identity_password", "client_certificate_path", "client_key_path", "certificate_provider", "certificate-provider", "bind_interface", "inet4_bind_address", "inet6_bind_address", "routing_mark", "routing-mark", "interface-name", "interface_name", "netns", "network_namespace", "protect_path", "reuse_addr", "tcp_fast_open", "tcp_multi_path", "tfo", "mptcp", "dialer-options", "plugin", "plugin-opts", "rule_set", "rule-set", "rule_set_ip_cidr_match_source", "geoip", "geosite", "process_name", "process_path", "process_path_regex", "package_name", "user", "user_id", "wifi_ssid", "wifi_bssid", "network_type", "network_is_expensive", "network_is_constrained", "preferred_by":
				// sing-box's certificate is an inline PEM list; Mihomo cert
				// and key strings can be paths and are never accepted here.
				if k == "certificate" {
					if err := providerInlineCertificate(child); err == nil {
						continue
					}
				}
				return providerUnsupported("внешний ресурс или системная настройка " + k)
			}
			if err := providerAssets(child); err != nil {
				return err
			}
		}
	case []any:
		for _, child := range value {
			if err := providerAssets(child); err != nil {
				return err
			}
		}
	}
	return nil
}

func providerInlineCertificate(value any) error {
	var text string
	switch value := value.(type) {
	case string:
		text = value
	case []any:
		for _, line := range value {
			s, ok := line.(string)
			if !ok {
				return providerUnsupported("inline certificate")
			}
			text += s + "\n"
		}
	default:
		return providerUnsupported("inline certificate")
	}
	remaining := []byte(text)
	count := 0
	for len(bytes.TrimSpace(remaining)) > 0 {
		if !bytes.HasPrefix(bytes.TrimSpace(remaining), []byte("-----BEGIN CERTIFICATE-----")) {
			return providerUnsupported("certificate должен содержать только PEM")
		}
		block, rest := pem.Decode(remaining)
		if block == nil || block.Type != "CERTIFICATE" {
			return providerUnsupported("неверный PEM certificate")
		}
		if _, err := x509.ParseCertificate(block.Bytes); err != nil {
			return providerUnsupported("неверный X509 certificate")
		}
		remaining = rest
		count++
	}
	if count == 0 {
		return providerUnsupported("пустой certificate")
	}
	return nil
}

func providerSingBox(p object, sp, hp int) error {
	if err := providerKeys(p, "log", "dns", "inbounds", "outbounds", "route", "experimental"); err != nil {
		return err
	}
	if err := normalizeProviderSingBoxCompatibility(p); err != nil { return err }
	inbounds, err := providerObjects(p["inbounds"], "inbounds", false)
	if err != nil {
		return err
	}
	for _, inbound := range inbounds {
		switch inbound["type"] {
		case "socks", "http", "mixed", "tun":
		default:
			return providerUnsupported("исходный inbound не является локальным SOCKS/HTTP/TUN listener")
		}
		if inbound["type"] != "tun" {
			if err := providerKeys(inbound, "type", "tag", "listen", "listen_port", "users", "set_system_proxy", "sniff", "sniff_override_destination", "domain_strategy"); err != nil {
				return err
			}
		}
		if (inbound["sniff"] != nil && inbound["sniff"] != false) || (inbound["sniff_override_destination"] != nil && inbound["sniff_override_destination"] != false) || inbound["domain_strategy"] != nil {
			return providerUnsupported("sniff/domain_strategy исходного inbound")
		}
	}
	outbounds, err := providerObjects(p["outbounds"], "outbounds", true)
	if err != nil {
		return err
	}
	for _, outbound := range outbounds {
		switch outbound["type"] {
		case "vless", "vmess", "trojan", "shadowsocks", "hysteria2", "socks", "http", "direct", "block", "dns", "selector", "urltest":
		default:
			return providerUnsupported("тип sing-box outbound")
		}
		if err := providerAssets(outbound); err != nil {
			return err
		}
	}
	if value, exists := p["route"]; exists {
		route, ok := value.(map[string]any)
		if !ok {
			return providerUnsupported("route")
		}
		if err := providerKeys(route, "rules", "final", "default_domain_resolver", "auto_detect_interface", "override_android_vpn"); err != nil {
			return err
		}
		if err := providerSBCompatRouteRules(route["rules"]); err != nil {
			return err
		}
		if err := providerAssets(route); err != nil {
			return err
		}
	}
	if value, exists := p["dns"]; exists {
		dns, ok := value.(map[string]any)
		if !ok {
			return providerUnsupported("dns")
		}
		if err := providerKeys(dns, "servers", "rules", "final", "strategy", "disable_cache", "disable_expire", "independent_cache", "cache_capacity", "reverse_mapping", "client_subnet"); err != nil {
			return err
		}
		servers, err := providerObjects(dns["servers"], "dns.servers", false)
		if err != nil {
			return err
		}
		for _, server := range servers {
			if err := providerKeys(server, "type", "tag", "server", "server_port", "address", "address_resolver", "address_strategy", "strategy", "detour", "domain_resolver", "tls", "path", "headers", "predefined", "timeout", "client_subnet", "inet4_range", "inet6_range"); err != nil {
				return err
			}
			if kind, _ := server["type"].(string); kind != "" {
				switch kind {
				case "local", "hosts", "udp", "tcp", "tls", "https", "quic", "h3", "fakeip":
				default:
					return providerUnsupported("тип DNS server")
				}
				if kind == "hosts" && server["path"] != nil {
					return providerUnsupported("DNS hosts file")
				}
			} else if address, _ := server["address"].(string); strings.Contains(address, "://") && !providerDNSAddress(address) {
				return providerUnsupported("DNS address")
			}
		}
		if err := providerSBRuleTree(dns["rules"]); err != nil {
			return err
		}
		if err := providerAssets(dns); err != nil {
			return err
		}
	}
	// Provider APIs/log files/listeners are replaced; approved FakeIP cache
	// state is retained at an application-controlled private relative path.
	p["log"] = object{"level": "warn"}
	p["inbounds"] = []any{object{"type": "socks", "tag": "svoi-socks", "listen": "127.0.0.1", "listen_port": sp}, object{"type": "http", "tag": "svoi-http", "listen": "127.0.0.1", "listen_port": hp}}
	return nil
}

func providerSBRuleTree(value any) error {
	if value == nil {
		return nil
	}
	rules, err := providerObjects(value, "rules", false)
	if err != nil {
		return err
	}
	for _, rule := range rules {
		for _, key := range []string{"source_ip_cidr", "source_ip_is_private", "source_port", "source_port_range"} {
			if rule[key] != nil {
				return providerUnsupported("условие правила зависит от исходного listener: " + key)
			}
		}
		if err := providerKeys(rule, "type", "mode", "rules", "invert", "domain", "domain_suffix", "domain_keyword", "domain_regex", "ip_cidr", "ip_is_private", "source_ip_cidr", "source_ip_is_private", "port", "port_range", "source_port", "source_port_range", "network", "protocol", "query_type", "outbound", "action", "method", "no_drop", "server", "strategy", "disable_cache", "rewrite_ttl", "client_subnet", "ip_version", "sniffer", "timeout"); err != nil {
			return err
		}
		if action, _ := rule["action"].(string); action != "" {
			switch action {
			case "route", "reject", "resolve", "sniff":
			default:
				return providerUnsupported("действие правила " + action)
			}
		}
		if err := providerSBRuleTree(rule["rules"]); err != nil {
			return err
		}
	}
	return nil
}

func providerDNSAddress(s string) bool {
	for _, prefix := range []string{"udp://", "tcp://", "tls://", "https://", "quic://", "h3://"} {
		if strings.HasPrefix(s, prefix) {
			return true
		}
	}
	return false
}

func providerMihomo(p object, sp, hp int) error {
	if err := providerKeys(p, "proxies", "proxy-groups", "rule-providers", "rules", "dns", "hosts", "mode", "ipv6", "log-level", "unified-delay", "tcp-concurrent", "global-client-fingerprint", "keep-alive-idle", "keep-alive-interval", "disable-keep-alive", "port", "socks-port", "mixed-port", "redir-port", "tproxy-port", "allow-lan", "bind-address", "authentication", "skip-auth-prefixes", "lan-allowed-ips", "lan-disallowed-ips", "external-controller", "external-controller-tls", "external-controller-unix", "external-controller-pipe", "external-ui", "external-ui-name", "external-ui-url", "secret", "external-cors", "tun", "listeners", "tunnels", "profile", "sniffer", "find-process-mode", "geodata-mode", "geodata-loader", "geox-url", "geo-auto-update", "geo-update-interval", "skip-dst"); err != nil {
		return err
	}
	if err := providerMihomoRuleAssets(p); err != nil {
		return err
	}
	// Some provider YAML templates retain this anchor as a top-level list.
	// v1.19.33 ignores it; its actual TUN/sniffer references are handled below.
	if value, exists := p["skip-dst"]; exists {
		values, ok := value.([]any)
		if !ok {
			return providerUnsupported("skip-dst annotation")
		}
		for _, value := range values {
			if _, ok := value.(string); !ok {
				return providerUnsupported("skip-dst annotation values")
			}
		}
	}
	if sniffer, exists := p["sniffer"]; exists {
		m, ok := sniffer.(map[string]any)
		if !ok {
			return providerUnsupported("sniffer")
		}
		if err := providerKeys(m, "enable", "force-dns-mapping", "parse-pure-ip", "override-destination", "sniff", "force-domain", "skip-domain", "skip-src-address", "skip-dst-address"); err != nil {
			return err
		}
		if err := providerAssets(m); err != nil {
			return err
		}
	}
	if value, exists := p["tunnels"]; exists {
		tunnels, ok := value.([]any)
		if !ok || len(tunnels) != 0 {
			return providerUnsupported("tunnels содержат самостоятельную переадресацию")
		}
	}
	if value, exists := p["listeners"]; exists {
		listeners, err := providerObjects(value, "listeners", false)
		if err != nil {
			return err
		}
		for _, listener := range listeners {
			switch listener["type"] {
			case "socks", "http", "mixed":
			default:
				return providerUnsupported("нестандартный Mihomo listener")
			}
			if err := providerKeys(listener, "name", "type", "port", "listen", "udp", "users"); err != nil {
				return err
			}
		}
	}
	proxies, err := providerObjects(p["proxies"], "proxies", true)
	if err != nil {
		return err
	}
	for _, proxy := range proxies {
		switch proxy["type"] {
		case "vless", "vmess", "trojan", "ss", "hysteria2", "socks5", "http", "direct", "reject":
		default:
			return providerUnsupported("тип Mihomo proxy")
		}
		if err := providerKeys(proxy, "name", "type", "server", "port", "uuid", "alterId", "cipher", "password", "username", "udp", "tls", "servername", "sni", "skip-cert-verify", "fingerprint", "client-fingerprint", "alpn", "network", "ws-opts", "grpc-opts", "http-opts", "h2-opts", "reality-opts", "flow", "packet-encoding", "smux", "dialer-proxy", "ip-version", "udp-over-tcp", "udp-over-tcp-version", "up", "down", "obfs", "obfs-password", "ports", "hop-interval", "fast-open", "disable-mtu-discovery"); err != nil {
			return err
		}
		if err := providerAssets(proxy); err != nil {
			return err
		}
	}
	groups, err := providerObjects(p["proxy-groups"], "proxy-groups", false)
	if err != nil {
		return err
	}
	for _, group := range groups {
		switch group["type"] {
		case "select", "url-test", "fallback", "load-balance":
		default:
			return providerUnsupported("тип Mihomo proxy-group")
		}
		if err := providerKeys(group, "name", "type", "proxies", "url", "interval", "lazy", "tolerance", "timeout", "max-failed-times", "expected-status", "disable-udp", "hidden", "icon", "strategy", "include-all", "include-all-proxies", "include-all-providers", "filter", "exclude-filter", "exclude-type", "empty-fallback", "default-selected"); err != nil {
			return err
		}
	}
	if value, exists := p["rules"]; exists {
		rules, ok := value.([]any)
		if !ok {
			return providerUnsupported("rules")
		}
		for _, value := range rules {
			rule, ok := value.(string)
			if !ok {
				return providerUnsupported("тип rules")
			}
			// Reject dependencies anywhere in logical expressions too.
			if providerUnsafeMHRule.MatchString(strings.ToUpper(rule)) {
				return providerUnsupported("правило с внешней или системной зависимостью")
			}
			kind := strings.SplitN(rule, ",", 2)[0]
			switch kind {
			case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX", "IP-CIDR", "IP-CIDR6", "IP-SUFFIX", "SRC-IP-CIDR", "SRC-IP-SUFFIX", "SRC-PORT", "DST-PORT", "NETWORK", "AND", "OR", "NOT", "MATCH", "RULE-SET", "PROCESS-NAME", "PROCESS-PATH", "PROCESS-NAME-REGEX", "PROCESS-PATH-REGEX":
			default:
				return providerUnsupported("тип правила " + kind)
			}
		}
	}
	if value, exists := p["dns"]; exists {
		dns, ok := value.(map[string]any)
		if !ok {
			return providerUnsupported("dns")
		}
		if err := providerKeys(dns, "enable", "listen", "ipv6", "cache-algorithm", "prefer-h3", "use-hosts", "use-system-hosts", "respect-rules", "default-nameserver", "nameserver", "fallback", "nameserver-policy", "proxy-server-nameserver", "proxy-server-nameserver-policy", "direct-nameserver", "direct-nameserver-follow-policy", "enhanced-mode", "fake-ip-range", "fake-ip-range6", "fake-ip-filter", "fake-ip-filter-mode", "fallback-filter"); err != nil {
			return err
		}
		if listen, exists := dns["listen"]; exists && listen != "" {
			return providerUnsupported("DNS listen: внешний DNS listener")
		}
		// v1.19.33 defaults fallback-filter.geoip to true and loads GeoIP
		// whenever fallback is nonempty. Requiring explicit false avoids an
		// implicit geodata download without changing resolver semantics.
		if value, exists := dns["fallback"]; exists {
			fallback, ok := value.([]any)
			if !ok {
				return providerUnsupported("dns.fallback")
			}
			if len(fallback) != 0 && obj(dns["fallback-filter"])["geoip"] != false {
				return providerUnsupported("DNS fallback требует явный fallback-filter.geoip: false без внешней GeoIP базы")
			}
		}
		if value, exists := dns["fallback-filter"]; exists {
			filter, ok := value.(map[string]any)
			if !ok {
				return providerUnsupported("dns.fallback-filter")
			}
			if err := providerKeys(filter, "geoip", "geoip-code", "geosite", "ipcidr", "domain"); err != nil {
				return err
			}
		}
		if err := providerMHDNS(dns); err != nil {
			return err
		}
	}
	// Geodata and interface-dependent modes must not trigger implicit downloads.
	for _, key := range []string{"geodata-mode", "geodata-loader", "geox-url", "geo-auto-update", "geo-update-interval"} {
		delete(p, key)
	}
	for _, key := range []string{"mixed-port", "redir-port", "tproxy-port", "authentication", "skip-auth-prefixes", "lan-allowed-ips", "lan-disallowed-ips", "external-controller", "external-controller-tls", "external-controller-unix", "external-controller-pipe", "external-ui", "external-ui-name", "external-ui-url", "secret", "external-cors", "tun", "listeners", "tunnels"} {
		delete(p, key)
	}
	p["port"], p["socks-port"] = hp, sp
	p["allow-lan"], p["bind-address"] = false, "127.0.0.1"
	// Native process matchers perform read-only connection/process lookup.
	// Preserve the provider's mode instead of silently disabling its rules.
	if value, exists := p["find-process-mode"]; exists {
		if value != "strict" && value != "always" && value != "off" {
			return providerUnsupported("find-process-mode")
		}
	}
	p["log-level"] = "warning"
	p["profile"] = object{"store-selected": false, "store-fake-ip": false}
	return nil
}

// Matcher types occur at the start of a rule or a parenthesized logical child.
// Provider/group names are payloads, and may themselves start with GEOIP etc.
var providerUnsafeMHRule = regexp.MustCompile(`(^|\()\s*(GEOIP|GEOSITE|IP-ASN|IN-[A-Z-]*|SRC-[A-Z-]*|SUB-RULE|SCRIPT|UID|DSCP),`)

func providerMHDNS(v any) error {
	switch value := v.(type) {
	case map[string]any:
		for key, child := range value {
			upper := strings.ToUpper(key)
			if key == "geoip" && child == false {
				continue
			}
			if key == "geoip-code" {
				continue
			} // inert when geoip is disabled
			if key == "geosite" {
				if list, ok := child.([]any); ok && len(list) == 0 {
					continue
				}
			}
			if strings.Contains(upper, "GEOSITE") || strings.Contains(upper, "RULE-SET") || key == "geoip" {
				return providerUnsupported("DNS geodata/rule provider")
			}
			if err := providerMHDNS(child); err != nil {
				return err
			}
		}
	case []any:
		for _, child := range value {
			if err := providerMHDNS(child); err != nil {
				return err
			}
		}
	case string:
		// Resolver URL suffixes can select a proxy group, but cannot request
		// an OS interface or ECS routing policy under application ownership.
		if strings.Contains(strings.ToLower(value), "geosite:") || providerUnsafeMHRule.MatchString(strings.ToUpper(value)) || strings.Contains(value, "#") || (strings.Contains(value, "://") && !providerDNSAddress(value)) {
			return providerUnsupported("DNS URL с системной или неподдерживаемой зависимостью")
		}
	}
	return nil
}
