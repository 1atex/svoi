package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/url"
	"strings"
)

// Rule data is downloaded by the native core, with its original URL, headers,
// proxy and update interval. Only its cache destination is application-owned.
// Paths are relative to Mihomo's private -d directory, never provider paths.
func providerMihomoRuleAssets(p object) error {
	value, exists := p["rule-providers"]
	if !exists {
		return nil
	}
	providers, ok := value.(map[string]any)
	if !ok || len(providers) > 128 {
		return providerUnsupported("rule-providers: требуется до 128 источников правил")
	}
	for name, value := range providers {
		provider, ok := value.(map[string]any)
		if !ok || name == "" {
			return providerUnsupported("неверный rule-provider")
		}
		if err := providerKeys(provider, "type", "url", "path", "proxy", "interval", "behavior", "format", "size-limit", "header"); err != nil {
			return err
		}
		if provider["type"] != "http" {
			return providerUnsupported("rule-provider: поддерживается только HTTP(S), не локальные файлы")
		}
		rawURL, ok := provider["url"].(string)
		u, err := url.Parse(rawURL)
		if !ok || err != nil || u == nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" || u.Opaque != "" || u.Fragment != "" {
			return providerUnsupported("rule-provider URL: требуется HTTP(S)")
		}
		if strings.ContainsAny(rawURL, "\r\n\x00") {
			return providerUnsupported("недопустимые символы rule-provider URL")
		}
		switch provider["behavior"] {
		case "domain", "ipcidr", "classical":
		default:
			return providerUnsupported("rule-provider behavior")
		}
		format := "yaml"
		if value, exists := provider["format"]; exists {
			format, ok = value.(string)
			if !ok {
				return providerUnsupported("rule-provider format")
			}
		}
		switch format {
		case "yaml", "text", "mrs":
		default:
			return providerUnsupported("rule-provider format")
		}
		if format == "mrs" && provider["behavior"] == "classical" {
			return providerUnsupported("MRS не поддерживает classical rules")
		}
		for _, key := range []string{"interval", "size-limit"} {
			if value, exists := provider[key]; exists {
				number, ok := value.(float64)
				if !ok || number < 0 || number != float64(int64(number)) {
					return providerUnsupported("rule-provider " + key)
				}
			}
		}
		if value, exists := provider["proxy"]; exists {
			if _, ok := value.(string); !ok {
				return providerUnsupported("rule-provider proxy")
			}
		}
		if value, exists := provider["header"]; exists {
			headers, ok := value.(map[string]any)
			if !ok {
				return providerUnsupported("rule-provider header")
			}
			for key, value := range headers {
				if key == "" || strings.ContainsAny(key, "\r\n:\x00") {
					return providerUnsupported("rule-provider HTTP header")
				}
				values, ok := value.([]any)
				if !ok {
					return providerUnsupported("rule-provider HTTP header values")
				}
				for _, value := range values {
					text, ok := value.(string)
					if !ok || strings.ContainsAny(text, "\r\n\x00") {
						return providerUnsupported("rule-provider HTTP header value")
					}
				}
			}
		}
		// Include headers and all fetch semantics in the cache identity so
		// subscriptions with different credentials never share cached rules.
		identity := object{"name": name}
		for key, value := range provider {
			if key != "path" {
				identity[key] = value
			}
		}
		raw, _ := json.Marshal(identity)
		hash := sha256.Sum256(raw)
		provider["path"] = "svoi-rule-assets/" + hex.EncodeToString(hash[:]) + "." + format
	}
	return nil
}
