package main

import "net/http"

func subscriptionResponseFormat(format string) string {
	if format == "" {
		return "auto"
	}
	return format
}

func validateResponseFormat(format string) error {
	switch format {
	case "", "auto", "sing-box", "mihomo":
		return nil
	}
	return fail(400, "Неизвестный формат подписки")
}

func applySubscriptionFormatHeaders(h http.Header, format string) {
	switch format {
	case "sing-box":
		h.Set("Accept", "application/json, text/plain;q=0.9, */*;q=0.1")
		h.Set("User-Agent", "singbox")
	case "mihomo":
		h.Set("Accept", "application/yaml, text/yaml, application/json, text/plain;q=0.9, */*;q=0.1")
		h.Set("User-Agent", "murge")
	default:
		h.Set("Accept", "application/json, text/plain, */*")
		if h.Get("User-Agent") == "" {
			h.Set("User-Agent", "Happ/0.4.1")
		}
	}
}
