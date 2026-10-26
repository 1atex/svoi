package backend

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

func TestSubscriptionMetadataHeaders(t *testing.T) {
	h := http.Header{}
	h.Set("announce", "base64:"+base64.StdEncoding.EncodeToString([]byte("До конца подписки 26521 дней")))
	h.Set("profile-title", "base64:"+base64.RawURLEncoding.EncodeToString([]byte("Моя подписка")))
	h.Set("subscription-userinfo", "upload=0; download=19657052396; total=0; expire=0")
	h.Set("profile-update-interval", "1")
	h.Set("support-url", "https://t.me/Support_bot")
	h.Set("sub-expire-button-link", "tg://resolve?domain=Support_bot")
	h.Set("routing", "happ://routing/add/"+base64.StdEncoding.EncodeToString([]byte(`{"Name":"Provider","DirectSites":["geosite:category-ru"]}`)))
	h.Set("subscription-always-hwid-enable", "1")
	h.Set("ping-type", "proxy")
	m := parseSubscriptionMetadata(h)
	if m.Title != "Моя подписка" || m.Announcement != "До конца подписки 26521 дней" || *m.Download != 19657052396 || *m.Total != 0 || *m.Expire != 0 || *m.Upload != 0 || m.UpdateHours != 1 {
		t.Fatalf("incorrect metadata: %+v", m)
	}
	if m.RenewURL != m.SupportURL || m.RoutingStatus != "happ-not-applied" || !json.Valid(m.Routing) || m.Hints["ping-type"] != "proxy" {
		t.Fatalf("links or provider hints lost: %+v", m)
	}
	if parseSubscriptionMetadata(http.Header{}) != nil {
		t.Fatal("empty metadata should be absent")
	}
}

func TestSubscriptionMetadataUntrustedValues(t *testing.T) {
	h := http.Header{}
	h.Set("subscription-userinfo", "upload=-1; download=NaN; total=999999999999999999999; expire=999999999999999")
	h.Set("announce", "base64:invalid!!!!")
	h.Set("profile-update-interval", "-2")
	h.Set("routing", "happ://routing/add/"+base64.StdEncoding.EncodeToString([]byte(`[]`)))
	h.Set("support-url", "file:///C:/Windows/system32/cmd.exe")
	m := parseSubscriptionMetadata(h)
	if m.Upload != nil || m.Download != nil || m.Total != nil || m.Expire != nil || m.Announcement != "" || m.UpdateHours != 0 || m.SupportURL != "" || m.Routing != nil || m.RoutingStatus != "unsupported" {
		t.Fatalf("invalid values accepted: %+v", m)
	}
	for _, link := range []string{"javascript:alert(1)", "https://user:pass@example.org", "tg://resolve?domain=../../bad", "https://example.org\r\nother", `https://example.org\bad`} {
		if subscriptionPublicLink(link) != "" {
			t.Fatalf("unsafe link accepted: %q", link)
		}
	}
	if text := metadataText(strings.Repeat("я", 200), 10); len([]rune(text)) != 10 {
		t.Fatal("unicode limit")
	}
}

func TestSubscriptionBodyMetadata(t *testing.T) {
	const node = "vless://test@example.com:443#Node"
	for _, content := range []string{
		"#profile-title: Body name\n#subscription-userinfo: total=100; expire=0\n" + node,
		base64.StdEncoding.EncodeToString([]byte("#profile-title: Body name\n" + node)),
		"#profile-title: Body name\n" + base64.StdEncoding.EncodeToString([]byte(node)),
	} {
		p, err := parseSubscription([]byte(content))
		if err != nil || len(p.Servers) != 1 {
			t.Fatalf("body parse: %+v %v", p, err)
		}
		m := parseSubscriptionMetadata(p.MetadataHeaders)
		if m.Title != "Body name" {
			t.Fatal("body header lost")
		}
		h := http.Header{}
		h.Set("profile-title", "HTTP name")
		if mergeSubscriptionMetadata(p.MetadataHeaders, h).Title != "HTTP name" {
			t.Fatal("HTTP header should take precedence")
		}
	}
}

func TestSubscriptionMetadataPersistenceAndReplacement(t *testing.T) {
	a := newTestApp(t)
	owner := create(t, a)
	id := expect(t, call(a, "POST", "/api/subscriptions", owner, input{Name: "Custom", URL: "https://example.org/private"}), 201)["id"].(string)
	status, title := 200, "Provider title"
	a.client = &http.Client{Transport: transportFunc(func(*http.Request) (*http.Response, error) {
		r := fakeResponse(status, "vless://test@example.com:443#Node")
		if title != "" {
			r.Header.Set("profile-title", title)
			r.Header.Set("subscription-userinfo", "download=100; total=0; expire=0")
		}
		return r, nil
	})}
	refresh := func(code int) { expect(t, call(a, "POST", "/api/subscription/refresh?id="+id, owner, nil), code) }
	refresh(200)
	s := &a.state.Groups[0].Subscriptions[0]
	if s.Name != "Custom" || s.Metadata.Title != title {
		t.Fatal("custom title overwritten or metadata lost")
	}
	restored, err := openApp(a.path)
	if err != nil || restored.state.Groups[0].Subscriptions[0].Metadata.Title != title {
		t.Fatalf("metadata not persisted: %v", err)
	}
	view := expect(t, call(a, "GET", "/api/me", owner, nil), 200)
	if !strings.Contains(string(mustJSON(t, view)), "Provider title") {
		t.Fatal("metadata absent from snapshot")
	}
	status = 503
	refresh(502)
	if s.Metadata.Title != title {
		t.Fatal("failed refresh cleared metadata")
	}
	status, title = 200, ""
	refresh(200)
	if s.Metadata != nil {
		t.Fatal("missing headers retained stale metadata")
	}
	title = "Again"
	refresh(200)
	expect(t, call(a, "PUT", "/api/subscriptions/"+id, owner, input{Name: "Custom", URL: "https://example.org/new"}), 200)
	if s.Metadata != nil {
		t.Fatal("new URL retained old metadata")
	}
}
