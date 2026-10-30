package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

func TestProviderProbeURLPolicy(t *testing.T) {
	metadata := &SubscriptionMetadata{Hints: map[string]string{"check-url-via-proxy": "http://ya.ru/"}}
	for _, test := range []struct {
		name     string
		settings ProbeSettings
		want     string
	}{
		{"default uses provider", ProbeSettings{}, "http://ya.ru/"},
		{"legacy custom preserved", ProbeSettings{URL: "https://example.org/check"}, "https://example.org/check"},
		{"explicit custom wins", ProbeSettings{URLSource: "custom"}, defaultProbeURL},
		{"provider with custom fallback", ProbeSettings{URLSource: "subscription", URL: "https://example.org/check"}, "http://ya.ru/"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := effectiveProbeSettings(test.settings, metadata); got.URL != test.want {
				t.Fatalf("got %q, want %q", got.URL, test.want)
			}
		})
	}
	for _, bad := range []string{"", "file:///etc/passwd", "https://user:pass@example.org/", "https://example.org/#fragment", "http://bad host/"} {
		metadata.Hints["check-url-via-proxy"] = bad
		if got := effectiveProbeSettings(ProbeSettings{}, metadata); got.URL != defaultProbeURL {
			t.Fatalf("accepted %q", bad)
		}
	}
	if validateProbeSettings(&ProbeSettings{URLSource: "unknown"}) == nil {
		t.Fatal("unknown URL source accepted")
	}
}

func TestProviderProbeUsesExactVariantMetadata(t *testing.T) {
	metadata := func(value string) *SubscriptionMetadata {
		return &SubscriptionMetadata{Hints: map[string]string{"check-url-via-proxy": value}}
	}
	g := &Group{Subscriptions: []Subscription{{ID: "source", Metadata: metadata("https://xray.test/"), Variants: map[string]SubscriptionVariantStatus{
		"mihomo":   {Metadata: metadata("https://mihomo.test/")},
		"sing-box": {Metadata: metadata("https://sing-box.test/")},
	}}}}
	for _, core := range []string{"mihomo", "sing-box"} {
		server := ServerConfig{ServerInfo: ServerInfo{SubscriptionID: "source", SubscriptionCore: core}}
		got := serverProbeSettings(ProbeSettings{}, g, server)
		if got.URL != "https://"+core+".test/" {
			t.Fatalf("%s metadata: %s", core, got.URL)
		}
	}
	g.Subscriptions[0].Variants["mihomo"] = SubscriptionVariantStatus{}
	server := ServerConfig{ServerInfo: ServerInfo{SubscriptionID: "source", SubscriptionCore: "mihomo"}}
	if got := serverProbeSettings(ProbeSettings{}, g, server); got.URL != defaultProbeURL {
		t.Fatalf("missing native metadata inherited another core URL: %s", got.URL)
	}
}

func TestProviderProbeAndConnectionUseSameURL(t *testing.T) {
	var hits atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Errorf("unexpected method %s", r.Method)
		}
		hits.Add(1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer target.Close()
	a := newTestApp(t)
	token := create(t, a)
	a.engine = &Engine{binary: testCore(t), dir: t.TempDir(), checkURL: "http://127.0.0.1:1/wrong", status: EngineStatus{Available: true, State: "stopped"}}
	defer a.engine.Stop()
	outbound, _ := json.Marshal(object{"protocol": "freedom", "settings": object{"finalRules": []any{object{"action": "allow", "ip": []string{"127.0.0.1"}}}}})
	a.state.Groups[0].Servers = []ServerConfig{{ServerInfo: ServerInfo{ID: "provider-node", SubscriptionID: "provider"}, Outbound: outbound}}
	a.state.Groups[0].Subscriptions = []Subscription{
		{ID: "other", Metadata: &SubscriptionMetadata{Hints: map[string]string{"check-url-via-proxy": "http://127.0.0.1:1/wrong"}}},
		{ID: "provider", Metadata: &SubscriptionMetadata{Hints: map[string]string{"check-url-via-proxy": target.URL}}},
	}
	result := expect(t, localProbeCall(a, "POST", "/api/servers/provider-node/probe", token, nil), 200)
	if result["url"] != target.URL {
		t.Fatal(result)
	}
	expect(t, localProbeCall(a, "POST", "/api/connection/start", token, map[string]string{"serverId": "provider-node", "mode": "local"}), 200)
	expect(t, localProbeCall(a, "POST", "/api/connection/check", token, nil), 200)
	if hits.Load() != 2 {
		t.Fatalf("got %d requests, expected probe and connection check", hits.Load())
	}
	if a.localSettings().Probe.URL != defaultProbeURL {
		t.Fatal("provider overwrote saved settings")
	}
}
