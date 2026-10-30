package main

import (
	"net/http"
	"regexp"
	"strings"
	"sync"
	"testing"
)

func TestSubscriptionRefreshUsesProviderUserAgentRules(t *testing.T) {
	rules := []struct{ pattern, response string }{
		{`(?i)^(?:flclash|flowvy|murge|mihomo|svoi|prizrak-box|koala-clash|clash(?:-verge|-nyanpasu|x meta|[-.]?meta))`, "mihomo"},
		{`(?i)^stash`, "stash"},
		{`(?i)^sfa|sfi|sfm|sft|karing|singbox|inhive`, "sing-box"},
		{`(?i)^clash`, "clash"},
	}
	responseType := func(h http.Header) string {
		if strings.Contains(h.Get("Accept"), "text/html") {
			return "browser"
		}
		for _, rule := range rules {
			if regexp.MustCompile(rule.pattern).MatchString(h.Get("User-Agent")) {
				return rule.response
			}
		}
		return "xray"
	}
	for _, test := range []struct{ ua, want string }{{"SVOI/0.7", "mihomo"}, {"clash/1", "clash"}, {"clash-meta/1", "mihomo"}} {
		h := http.Header{"User-Agent": []string{test.ua}}
		if got := responseType(h); got != test.want {
			t.Fatalf("fixture routing %s: %s", test.ua, got)
		}
	}
	a, token, id := variantTestSubscription(t)
	a.state.Groups[0].Identity.UserAgent = "SVOI/0.7"
	identity := a.state.Groups[0].Identity
	var mu sync.Mutex
	counts := map[string]int{}
	a.client = &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		core := responseType(r.Header)
		mu.Lock()
		counts[core]++
		mu.Unlock()
		for key, value := range headers(identity) {
			if key != "User-Agent" && r.Header.Get(key) != value {
				t.Errorf("changed device header %s", key)
			}
		}
		if core != "xray" && core != "sing-box" && core != "mihomo" {
			return fakeResponse(400, "wrong format"), nil
		}
		return fakeResponse(200, variantTestBody(core, 1)), nil
	})}
	expect(t, call(a, "POST", "/api/subscription/refresh?id="+id, token, nil), 200)
	for _, core := range subscriptionVariantCores {
		if counts[core] != 1 || a.state.Groups[0].Subscriptions[0].Variants[core].State != "ready" {
			t.Fatalf("missing negotiated %s: %v", core, counts)
		}
	}
	if a.state.Groups[0].Identity != identity {
		t.Fatal("format negotiation rewrote shared identity")
	}
}

func TestSubscriptionNativeFormatNegotiation(t *testing.T) {
	for _, format := range []string{"auto", "sing-box", "mihomo"} {
		t.Run(format, func(t *testing.T) {
			a := newTestApp(t)
			token := create(t, a)
			identity := a.state.Groups[0].Identity
			id := expect(t, call(a, "POST", "/api/subscriptions", token, input{Name: "Native", URL: "https://provider.example/private", ResponseFormat: &format}), 201)["id"].(string)
			var sentMu sync.Mutex
			sent := map[string]http.Header{}
			broken := false
			a.client = &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
				sentMu.Lock()
				sent[r.Header.Get("User-Agent")] = r.Header.Clone()
				sentMu.Unlock()
				if broken {
					return fakeResponse(200, "<html>Login</html>"), nil
				}
				body := "vless://test@example.com:443#Node"
				switch format {
				case "sing-box":
					body = `{"outbounds":[{"type":"vless","tag":"node","server":"example.org","server_port":443,"uuid":"00000000-0000-4000-8000-000000000001"}],"route":{"final":"node"}}`
				case "mihomo":
					body = "proxies:\n  - name: node\n    type: vless\n    server: example.org\n    port: 443\n    uuid: 00000000-0000-4000-8000-000000000001\nrules:\n  - MATCH,node\n"
				}
				response := fakeResponse(200, body)
				response.Header.Set("check-url-via-proxy", "http://ya.ru/")
				return response, nil
			})}
			expect(t, call(a, "POST", "/api/subscription/refresh?id="+id, token, nil), 200)
			for _, requested := range []string{"auto", "sing-box", "mihomo"} {
				expected := make(http.Header)
				for key, value := range headers(identity) {
					expected.Set(key, value)
				}
				applySubscriptionFormatHeaders(expected, requested)
				actual := sent[expected.Get("User-Agent")]
				for key, values := range expected {
					if actual.Get(key) != values[0] {
						t.Fatalf("identity/format header changed for %s: %s", requested, key)
					}
				}
				if strings.Contains(actual.Get("Accept"), "text/html") {
					t.Fatal("browser response requested")
				}
				if requested == "sing-box" && !regexp.MustCompile(`^sfa|sfi|sfm|sft|karing|singbox|inhive`).MatchString(actual.Get("User-Agent")) {
					t.Fatal("sing-box provider rule did not match")
				}
				if requested == "mihomo" && actual.Get("User-Agent") != "murge" {
					t.Fatal("Mihomo provider rule did not match")
				}
			}
			server := a.state.Groups[0].Servers[0]
			if format != "auto" && server.SourceProfileCore != format {
				t.Fatal("native core lost")
			}
			restored, err := openApp(a.path)
			if err != nil {
				t.Fatal(err)
			}
			if restored.state.Groups[0].Subscriptions[0].ResponseFormat != format {
				t.Fatal("format not persisted")
			}
			if len(restored.state.Groups[0].Servers[0].Protocols) == 0 && format != "auto" {
				t.Fatal("protocols erased on reopen")
			}
			broken = true
			expect(t, call(a, "POST", "/api/subscription/refresh?id="+id, token, nil), 422)
			if a.state.Groups[0].Servers[0].ID != server.ID {
				t.Fatal("failed refresh destroyed cached profile")
			}
			code, err := encodeTransfer(&a.state.Groups[0])
			if err != nil {
				t.Fatal(err)
			}
			group, err := decodeTransfer(code)
			if err != nil || group.Subscriptions[0].ResponseFormat != format {
				t.Fatalf("transfer lost format: %v", err)
			}
			if format != "auto" {
				a.state.Groups[0].Subscriptions[0].URL = ""
				code, err = encodeTransfer(&a.state.Groups[0])
				if err != nil {
					t.Fatal(err)
				}
				group, err = decodeTransfer(code)
				if err != nil || len(group.Servers) != 1 || group.Servers[0].SourceProfileCore != format {
					t.Fatalf("embedded native profile lost: %v", err)
				}
				if _, err := speedServerConfig(group.Servers[0]); err == nil {
					t.Fatal("native speed test must not silently use DIRECT")
				}
				expect(t, localProbeCall(a, "POST", "/api/servers/"+server.ID+"/extract-nodes", token, map[string]bool{"acknowledgeProfileRulesOmitted": true}), 422)
			}
		})
	}
}

func TestSubscriptionFormatUpdatesPreserveOmittedValue(t *testing.T) {
	a := newTestApp(t)
	token := create(t, a)
	format := "mihomo"
	id := expect(t, call(a, "POST", "/api/subscriptions", token, input{Name: "Native", URL: "https://provider.example/private", ResponseFormat: &format}), 201)["id"].(string)
	expect(t, call(a, "PUT", "/api/subscriptions/"+id, token, input{Name: "Renamed"}), 200)
	if a.state.Groups[0].Subscriptions[0].ResponseFormat != format {
		t.Fatal("rename reset format")
	}
	bad := "browser"
	expect(t, call(a, "PUT", "/api/subscriptions/"+id, token, input{Name: "Renamed", ResponseFormat: &bad}), 400)
}
