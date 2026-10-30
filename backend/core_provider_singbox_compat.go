package main

import (
	"encoding/json"
	"net/netip"
	"net/url"
	"reflect"
	"runtime"
	"strconv"
	"strings"
)

const providerSingBoxCachePath = "svoi-provider-cache.db"

// Normalize the bounded legacy DNS schema used by provider templates to the
// bundled sing-box schema. This must run on the runtime copy, never saved input.
// Upstream references: sing-box migration 1.12 DNS server/outbound rule migration
// and migration 1.14 independent cache removal.
func normalizeProviderSingBoxCompatibility(p object) error {
	route := object{}
	if value, exists := p["route"]; exists {
		var ok bool
		route, ok = value.(map[string]any)
		if !ok {
			return providerUnsupported("route")
		}
	}
	for _, key := range []string{"auto_detect_interface", "override_android_vpn"} {
		if value, exists := route[key]; exists {
			if _, ok := value.(bool); !ok {
				return providerUnsupported("тип route." + key)
			}
		}
	}
	// This Android-only option is rejected even at config-check time on desktop.
	// It cannot affect desktop routing; retaining auto_detect_interface preserves
	// the provider's actual outbound-interface policy on supported platforms.
	if runtime.GOOS != "android" {
		delete(route, "override_android_vpn")
	}
	if err := normalizeProviderSBLegacySniff(p, route); err != nil {
		return err
	}
	if value, exists := p["dns"]; exists {
		dns, ok := value.(map[string]any)
		if !ok {
			return providerUnsupported("dns")
		}
		if err := normalizeProviderSBDNS(p, dns, route); err != nil {
			return err
		}
	}
	if len(route) > 0 {
		p["route"] = route
	}
	return normalizeProviderSBExperimental(p)
}

type providerSBDNSDefaults struct {
	strategy string
	subnet   any
}

func normalizeProviderSBLegacySniff(p, route object) error {
	inbounds, err := providerObjects(p["inbounds"], "inbounds", false)
	if err != nil {
		return err
	}
	anySniff := false
	for _, inbound := range inbounds {
		anySniff = anySniff || inbound["sniff"] == true
	}
	if !anySniff {
		return nil
	}
	rules, err := providerObjects(route["rules"], "route.rules", false)
	if err != nil {
		return err
	}
	globalDefault := len(rules) > 0 && len(rules[0]) == 1 && rules[0]["action"] == "sniff"
	if !globalDefault {
		return providerUnsupported("legacy sniff требует эквивалентное общее route sniff правило")
	}
	for _, inbound := range inbounds {
		if inbound["sniff"] == true {
			delete(inbound, "sniff")
		}
	}
	return nil
}

func normalizeProviderSBDNS(p, dns, route object) error {
	if value, exists := dns["independent_cache"]; exists {
		if _, ok := value.(bool); !ok {
			return providerUnsupported("тип dns.independent_cache")
		}
		delete(dns, "independent_cache")
	}
	servers, err := providerObjects(dns["servers"], "dns.servers", false)
	if err != nil {
		return err
	}
	defaults := map[string]providerSBDNSDefaults{}
	legacyFake, hasLegacyFake := dns["fakeip"]
	fakeOptions := object{}
	if hasLegacyFake {
		var ok bool
		fakeOptions, ok = legacyFake.(map[string]any)
		if !ok {
			return providerUnsupported("legacy dns.fakeip")
		}
		if err := providerKeys(fakeOptions, "enabled", "inet4_range", "inet6_range"); err != nil {
			return err
		}
		if value, exists := fakeOptions["enabled"]; exists {
			if _, ok := value.(bool); !ok {
				return providerUnsupported("тип dns.fakeip.enabled")
			}
		}
		for _, key := range []string{"inet4_range", "inet6_range"} {
			if value, exists := fakeOptions[key]; exists {
				text, ok := value.(string)
				prefix, err := netip.ParsePrefix(text)
				if !ok || err != nil || (key == "inet4_range") != prefix.Addr().Is4() {
					return providerUnsupported("диапазон legacy FakeIP")
				}
			}
		}
	}
	seenFake := false
	for _, server := range servers {
		kind, _ := server["type"].(string)
		if kind != "" {
			if kind == "fakeip" {
				seenFake = true
			}
			continue
		}
		if err := providerKeys(server, "tag", "address", "address_resolver", "address_strategy", "strategy", "detour", "client_subnet"); err != nil {
			return err
		}
		if err := nativeStringFields(server, "tag", "address", "address_resolver", "address_strategy", "strategy", "detour"); err != nil {
			return err
		}
		strategy := str(server["strategy"])
		if !providerSBStrategy(strategy) {
			return providerUnsupported("legacy DNS strategy")
		}
		addressStrategy := str(server["address_strategy"])
		if !providerSBStrategy(addressStrategy) {
			return providerUnsupported("legacy DNS address_strategy")
		}
		tag := str(server["tag"])
		if strategy != "" || server["client_subnet"] != nil {
			if tag == "" {
				return providerUnsupported("legacy DNS options требуют tag")
			}
			defaults[tag] = providerSBDNSDefaults{strategy, server["client_subnet"]}
		}
		address := str(server["address"])
		converted := object{}
		if tag != "" {
			converted["tag"] = tag
		}
		switch address {
		case "local":
			if str(server["detour"]) != "" || str(server["address_resolver"]) != "" {
				return providerUnsupported("legacy local DNS с detour/resolver")
			}
			converted["type"] = "local"
		case "fakeip":
			if !hasLegacyFake || fakeOptions["enabled"] != true {
				return providerUnsupported("legacy FakeIP без включённых диапазонов")
			}
			if strategy != "" || server["client_subnet"] != nil || str(server["detour"]) != "" || str(server["address_resolver"]) != "" {
				return providerUnsupported("неподдерживаемые legacy FakeIP options")
			}
			converted["type"] = "fakeip"
			for _, key := range []string{"inet4_range", "inet6_range"} {
				if value, exists := fakeOptions[key]; exists {
					converted[key] = value
				}
			}
			seenFake = true
		default:
			endpoint, err := providerSBLegacyDNSEndpoint(address)
			if err != nil {
				return err
			}
			for key, value := range endpoint {
				converted[key] = value
			}
			detour := str(server["detour"])
			if detour == "" {
				detour, err = providerSBDefaultOutbound(p, route)
				if err != nil {
					return err
				}
			}
			// Legacy DNS uses the default outbound; new typed DNS defaults to
			// direct. Pin the original default explicitly to avoid a DNS leak.
			converted["detour"] = detour
			if _, err := netip.ParseAddr(str(converted["server"])); err != nil {
				resolver := str(server["address_resolver"])
				if resolver == "" {
					return providerUnsupported("legacy DNS hostname без address_resolver")
				}
				options := object{"server": resolver}
				if addressStrategy == "" {
					addressStrategy = str(dns["strategy"])
				}
				if addressStrategy != "" {
					options["strategy"] = addressStrategy
				}
				converted["domain_resolver"] = options
			}
		}
		for key := range server {
			delete(server, key)
		}
		for key, value := range converted {
			server[key] = value
		}
	}
	if hasLegacyFake {
		if fakeOptions["enabled"] == true && !seenFake {
			return providerUnsupported("legacy FakeIP без DNS server")
		}
		delete(dns, "fakeip")
	}
	rules, err := providerObjects(dns["rules"], "dns.rules", false)
	if err != nil {
		return err
	}
	kept := []any{}
	bootstrapFound := false
	for _, rule := range rules {
		if value, exists := rule["outbound"]; exists {
			if bootstrapFound || !providerSBAnyOutbound(value) {
				return providerUnsupported("условные или повторяющиеся legacy DNS outbound rules")
			}
			if err := providerKeys(rule, "outbound", "server", "action", "strategy", "disable_cache", "rewrite_ttl", "client_subnet"); err != nil {
				return err
			}
			if action := str(rule["action"]); action != "" && action != "route" {
				return providerUnsupported("legacy DNS outbound action")
			}
			server, ok := rule["server"].(string)
			if !ok || server == "" {
				return providerUnsupported("legacy DNS outbound server")
			}
			options := object{"server": server}
			for _, key := range []string{"strategy", "disable_cache", "rewrite_ttl", "client_subnet"} {
				if value, exists := rule[key]; exists {
					options[key] = value
				}
			}
			providerSBFillDNSDefaults(options, defaults[server])
			if previous, exists := route["default_domain_resolver"]; exists && !providerSBResolverEqual(previous, options) {
				return providerUnsupported("конфликт legacy DNS outbound rule и default_domain_resolver")
			}
			route["default_domain_resolver"] = options
			bootstrapFound = true
			continue
		}
		if providerSBContainsKey(rule, "outbound") {
			return providerUnsupported("вложенный legacy DNS outbound rule")
		}
		if err := providerSBApplyDNSRuleDefaults(rule, defaults, providerSBContainsKey(dns["rules"], "query_type")); err != nil {
			return err
		}
		kept = append(kept, rule)
	}
	if _, exists := dns["rules"]; exists {
		dns["rules"] = kept
	}
	final := str(dns["final"])
	if final == "" && len(servers) > 0 {
		final = str(servers[0]["tag"])
	}
	if options, exists := defaults[final]; exists {
		if options.strategy != "" {
			dns["strategy"] = options.strategy
		}
		if options.subnet != nil {
			dns["client_subnet"] = options.subnet
		}
	}
	providerSBApplyResolverDefaults(p, defaults)
	providerSBNormalizeEmptyDirectDNSDetours(p, servers)
	return nil
}

func providerSBNormalizeEmptyDirectDNSDetours(p object, servers []object) {
	// Typed DNS already uses a plain direct dialer when detour is absent.
	// sing-box accepts an explicit detour at check time but rejects it at start
	// if it references an empty direct outbound. Only type/tag-only objects are
	// provably interchangeable; every configured option remains authoritative.
	outs, ok := p["outbounds"].([]any)
	if !ok {
		return
	}
	counts := map[string]int{}
	empty := map[string]bool{}
	for _, value := range outs {
		out, ok := value.(map[string]any)
		if !ok {
			continue
		}
		tag, ok := out["tag"].(string)
		if !ok || tag == "" {
			continue
		}
		counts[tag]++
		plain := out["type"] == "direct"
		for key := range out {
			if key != "type" && key != "tag" {
				plain = false
				break
			}
		}
		empty[tag] = plain
	}
	for _, server := range servers {
		tag, ok := server["detour"].(string)
		if ok && counts[tag] == 1 && empty[tag] {
			delete(server, "detour")
		}
	}
}

func providerSBApplyResolverDefaults(value any, defaults map[string]providerSBDNSDefaults) {
	switch value := value.(type) {
	case map[string]any:
		for key, child := range value {
			if key == "domain_resolver" || key == "default_domain_resolver" {
				if tag, ok := child.(string); ok {
					options := defaults[tag]
					if options.strategy != "" || options.subnet != nil {
						resolver := object{"server": tag}
						providerSBFillDNSDefaults(resolver, options)
						value[key] = resolver
					}
				} else if resolver, ok := child.(map[string]any); ok {
					providerSBFillDNSDefaults(resolver, defaults[str(resolver["server"])])
				}
			} else {
				providerSBApplyResolverDefaults(child, defaults)
			}
		}
	case []any:
		for _, child := range value {
			providerSBApplyResolverDefaults(child, defaults)
		}
	}
}

func providerSBStrategy(value string) bool {
	switch value {
	case "", "prefer_ipv4", "prefer_ipv6", "ipv4_only", "ipv6_only":
		return true
	}
	return false
}
func providerSBAnyOutbound(value any) bool {
	if value == "any" {
		return true
	}
	items, ok := value.([]any)
	return ok && len(items) == 1 && items[0] == "any"
}
func providerSBResolverEqual(value any, options object) bool {
	if text, ok := value.(string); ok {
		value = object{"server": text}
	}
	return reflect.DeepEqual(value, options)
}
func providerSBFillDNSDefaults(options object, defaults providerSBDNSDefaults) {
	if _, exists := options["strategy"]; !exists && defaults.strategy != "" {
		options["strategy"] = defaults.strategy
	}
	if _, exists := options["client_subnet"]; !exists && defaults.subnet != nil {
		options["client_subnet"] = defaults.subnet
	}
}
func providerSBApplyDNSRuleDefaults(rule object, defaults map[string]providerSBDNSDefaults, queryType bool) error {
	if tag, ok := rule["server"].(string); ok {
		options := defaults[tag]
		if options.strategy != "" && queryType {
			return providerUnsupported("legacy DNS server strategy с query_type вне bootstrap rule")
		}
		providerSBFillDNSDefaults(rule, options)
	}
	if nested, exists := rule["rules"]; exists {
		rules, err := providerObjects(nested, "dns.rules.rules", false)
		if err != nil {
			return err
		}
		for _, child := range rules {
			if err := providerSBApplyDNSRuleDefaults(child, defaults, queryType); err != nil {
				return err
			}
		}
	}
	return nil
}
func providerSBContainsKey(value any, key string) bool {
	switch value := value.(type) {
	case map[string]any:
		if _, exists := value[key]; exists {
			return true
		}
		for _, child := range value {
			if providerSBContainsKey(child, key) {
				return true
			}
		}
	case []any:
		for _, child := range value {
			if providerSBContainsKey(child, key) {
				return true
			}
		}
	}
	return false
}

func providerSBDefaultOutbound(p, route object) (string, error) {
	if tag, ok := route["final"].(string); ok && tag != "" {
		return tag, nil
	}
	outs, err := providerObjects(p["outbounds"], "outbounds", true)
	if err != nil {
		return "", err
	}
	if tag := str(outs[0]["tag"]); tag != "" {
		return tag, nil
	}
	used := map[string]bool{}
	for _, out := range outs {
		used[str(out["tag"])] = true
	}
	tag := "svoi-legacy-dns-default"
	for used[tag] {
		tag += "-"
	}
	outs[0]["tag"] = tag
	return tag, nil
}

func providerSBLegacyDNSEndpoint(address string) (object, error) {
	if address == "" {
		return nil, providerUnsupported("пустой legacy DNS address")
	}
	if _, err := netip.ParseAddr(address); err == nil {
		return object{"type": "udp", "server": address}, nil
	}
	if !strings.Contains(address, "://") {
		address = "udp://" + address
	}
	parsed, err := url.Parse(address)
	if err != nil || parsed.User != nil || parsed.Hostname() == "" || parsed.Fragment != "" || parsed.RawQuery != "" || strings.Contains(parsed.Hostname(), "%") {
		return nil, providerUnsupported("legacy DNS address")
	}
	switch parsed.Scheme {
	case "udp", "tcp", "tls", "https", "quic", "h3":
	default:
		return nil, providerUnsupported("протокол legacy DNS address")
	}
	if parsed.Path != "" && parsed.Scheme != "https" && parsed.Scheme != "h3" {
		return nil, providerUnsupported("путь legacy DNS address")
	}
	result := object{"type": parsed.Scheme, "server": parsed.Hostname()}
	if port := parsed.Port(); port != "" {
		n, err := strconv.Atoi(port)
		if err != nil || n < 1 || n > 65535 {
			return nil, providerUnsupported("порт legacy DNS address")
		}
		result["server_port"] = n
	}
	if parsed.Path != "" && (parsed.Scheme == "https" || parsed.Scheme == "h3") {
		result["path"] = parsed.EscapedPath()
	}
	return result, nil
}

func normalizeProviderSBExperimental(p object) error {
	value, exists := p["experimental"]
	if !exists {
		return nil
	}
	experimental, ok := value.(map[string]any)
	if !ok {
		return providerUnsupported("experimental")
	}
	if err := providerKeys(experimental, "clash_api", "v2ray_api", "cache_file"); err != nil {
		return err
	}
	delete(p, "experimental")
	value, exists = experimental["cache_file"]
	if !exists {
		return nil
	}
	cache, ok := value.(map[string]any)
	if !ok {
		return providerUnsupported("experimental.cache_file")
	}
	if err := providerKeys(cache, "enabled", "path", "cache_id", "store_fakeip", "store_rdrc", "rdrc_timeout", "store_dns"); err != nil {
		return err
	}
	for _, key := range []string{"enabled", "store_fakeip", "store_rdrc", "store_dns"} {
		if value, exists := cache[key]; exists {
			if _, ok := value.(bool); !ok {
				return providerUnsupported("тип cache_file." + key)
			}
		}
	}
	if err := nativeStringFields(cache, "path", "cache_id", "rdrc_timeout"); err != nil {
		return err
	}
	// The application owns listener/control APIs and selector state. FakeIP
	// persistence is data-plane state and must survive the runtime adaptation.
	if cache["enabled"] == true && cache["store_fakeip"] == true {
		cache["path"] = providerSingBoxCachePath
		// Namespace persisted address mappings by the effective graph instead of
		// allowing unrelated subscriptions to collide through a provider cache ID.
		identity, _ := json.Marshal(object{"profile": p, "provider_cache_id": cache["cache_id"]})
		cache["cache_id"] = "svoi-" + digest(string(identity))[:24]
		p["experimental"] = object{"cache_file": cache}
	}
	return nil
}

func providerSBCompatRouteRules(value any) error {
	// hijack-dns is valid for the bundled core; validate every other field using
	// the common rule guard without dropping the action from the runtime graph.
	raw, err := json.Marshal(value)
	if err != nil {
		return providerUnsupported("route.rules")
	}
	var validation any
	if json.Unmarshal(raw, &validation) != nil {
		return providerUnsupported("route.rules")
	}
	var adapt func(any)
	adapt = func(value any) {
		switch value := value.(type) {
		case map[string]any:
			if value["action"] == "hijack-dns" {
				delete(value, "action")
			}
			for _, child := range value {
				adapt(child)
			}
		case []any:
			for _, child := range value {
				adapt(child)
			}
		}
	}
	adapt(validation)
	return providerSBRuleTree(validation)
}
