package backend

import (
	"encoding/json"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

type SubscriptionMetadata struct {
	Title          string            `json:"title,omitempty"`
	Announcement   string            `json:"announcement,omitempty"`
	Upload         *int64            `json:"upload,omitempty"`
	Download       *int64            `json:"download,omitempty"`
	Total          *int64            `json:"total,omitempty"`
	Expire         *int64            `json:"expire,omitempty"`
	UpdateHours    int               `json:"updateHours,omitempty"`
	SupportURL     string            `json:"supportUrl,omitempty"`
	WebURL         string            `json:"webUrl,omitempty"`
	InfoText       string            `json:"infoText,omitempty"`
	InfoButtonText string            `json:"infoButtonText,omitempty"`
	InfoURL        string            `json:"infoUrl,omitempty"`
	RenewURL       string            `json:"renewUrl,omitempty"`
	Routing        json.RawMessage   `json:"routing,omitempty"`
	RoutingStatus  string            `json:"routingStatus,omitempty"`
	Hints          map[string]string `json:"hints,omitempty"`
}

var subscriptionMetadataKeys = []string{
	"profile-title", "announce", "subscription-userinfo", "profile-update-interval",
	"support-url", "profile-web-page-url", "sub-info-text", "sub-info-button-text",
	"sub-info-button-link", "sub-expire-button-link", "routing", "ping-type",
	"check-url-via-proxy", "subscription-always-hwid-enable", "subscription-pin",
	"subscription-ping-onopen-enabled", "subscriptions-collapse", "hide-settings",
	"sub-expire", "providerid",
}

func stripSubscriptionMetadata(s string, h http.Header) string {
	lines := strings.Split(s, "\n")
	kept := lines[:0]
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "#") {
			key, value, ok := strings.Cut(strings.TrimSpace(trimmed[1:]), ":")
			if ok {
				for _, allowed := range subscriptionMetadataKeys {
					if strings.EqualFold(strings.TrimSpace(key), allowed) && len(value) <= 65536 {
						h.Set(allowed, strings.TrimSpace(value))
						break
					}
				}
			}
			continue
		}
		kept = append(kept, line)
	}
	return strings.TrimSpace(strings.Join(kept, "\n"))
}

func metadataText(raw string, limit int) string {
	if len(raw) > 65536 {
		return ""
	}
	if strings.HasPrefix(raw, "base64:") {
		b, err := decodeBase64(strings.TrimPrefix(raw, "base64:"))
		if err != nil {
			return ""
		}
		raw = string(b)
	}
	if !utf8.ValidString(raw) {
		return ""
	}
	raw = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) && r != '\n' && r != '\t' {
			return -1
		}
		return r
	}, raw)
	runes := []rune(strings.TrimSpace(raw))
	if len(runes) > limit {
		runes = runes[:limit]
	}
	return string(runes)
}

func subscriptionPublicLink(raw string) string {
	if len(raw) > 2048 || strings.ContainsAny(raw, "\r\n\t\\") {
		return ""
	}
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.User != nil {
		return ""
	}
	if u.Scheme == "tg" && u.Host == "resolve" {
		domain := u.Query().Get("domain")
		if len(domain) == 0 || len(domain) > 64 {
			return ""
		}
		for _, c := range domain {
			if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_') {
				return ""
			}
		}
		return "https://t.me/" + domain
	}
	if u.Scheme != "https" || u.Hostname() == "" {
		return ""
	}
	return u.String()
}

func parseSubscriptionMetadata(h http.Header) *SubscriptionMetadata {
	if len(h) == 0 {
		return nil
	}
	m := &SubscriptionMetadata{
		Title: metadataText(h.Get("profile-title"), 120), Announcement: metadataText(h.Get("announce"), 2000),
		SupportURL: subscriptionPublicLink(h.Get("support-url")), WebURL: subscriptionPublicLink(h.Get("profile-web-page-url")),
		InfoText: metadataText(h.Get("sub-info-text"), 500), InfoButtonText: metadataText(h.Get("sub-info-button-text"), 60),
		InfoURL: subscriptionPublicLink(h.Get("sub-info-button-link")), RenewURL: subscriptionPublicLink(h.Get("sub-expire-button-link")),
	}
	for _, field := range strings.Split(h.Get("subscription-userinfo"), ";") {
		key, raw, ok := strings.Cut(field, "=")
		if !ok {
			continue
		}
		n, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
		if err != nil || n < 0 || n > 9007199254740991 {
			continue
		}
		switch strings.ToLower(strings.TrimSpace(key)) {
		case "upload":
			m.Upload = &n
		case "download":
			m.Download = &n
		case "total":
			m.Total = &n
		case "expire":
			if n <= 253402300799 {
				m.Expire = &n
			}
		}
	}
	if n, err := strconv.Atoi(h.Get("profile-update-interval")); err == nil && n > 0 && n <= 8760 {
		m.UpdateHours = n
	}
	if raw := h.Get("routing"); raw != "" {
		m.RoutingStatus = "unsupported"
		const prefix = "happ://routing/add/"
		if len(raw) <= 65536 && strings.HasPrefix(raw, prefix) {
			if b, err := decodeBase64(strings.TrimPrefix(raw, prefix)); err == nil {
				var obj map[string]json.RawMessage
				if json.Unmarshal(b, &obj) == nil && obj != nil {
					m.Routing, _ = json.Marshal(obj)
					m.RoutingStatus = "happ-not-applied"
				}
			}
		}
	}
	for _, key := range subscriptionMetadataKeys[11:] {
		if key == "routing" {
			continue
		}
		if value := metadataText(h.Get(key), 2048); value != "" {
			if m.Hints == nil {
				m.Hints = map[string]string{}
			}
			m.Hints[key] = value
		}
	}
	b, _ := json.Marshal(m)
	if string(b) == "{}" {
		return nil
	}
	return m
}

func mergeSubscriptionMetadata(body, response http.Header) *SubscriptionMetadata {
	merged := body.Clone()
	if merged == nil {
		merged = http.Header{}
	}
	for _, key := range subscriptionMetadataKeys {
		if values, ok := response[http.CanonicalHeaderKey(key)]; ok {
			merged[http.CanonicalHeaderKey(key)] = values
		}
	}
	return parseSubscriptionMetadata(merged)
}
