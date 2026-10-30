package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
)

func nativeProviderTestProfile(t *testing.T, parsed ParsedSubscription, core string) ServerConfig {
	t.Helper()
	if len(parsed.Servers) != 1 {
		t.Fatalf("expected one complete profile, got %d", len(parsed.Servers))
	}
	s := parsed.Servers[0]
	if !s.FullProfile || s.SourceProfileCore != core || len(s.Profile) == 0 || s.Outbound != nil || s.Address != "" || s.Port != 0 {
		t.Fatal("native profile was flattened or lost its source", s.ServerInfo)
	}
	return s
}

func TestNativeProviderSingBoxJSONPreservesCompleteGraph(t *testing.T) {
	const content = `{
      "outbounds":[{"type":"selector","tag":"entry","outbounds":["node-b","node-a"]},
        {"type":"vless","tag":"node-a","server":"a.invalid","server_port":443,"uuid":"private-uuid"},
        {"type":"hysteria2","tag":"node-b","server":"b.invalid","server_port":443,"password":"private-password"},
        {"type":"vless","tag":"node-c","server":"c.invalid"},{"type":"urltest","tag":"automatic","outbounds":["node-a"]},
        {"type":"direct","tag":"direct"},{"type":"block","tag":"block"}],
      "route":{"final":"entry","rules":[{"domain_suffix":["internal.test"],"outbound":"direct"}]},
      "dns":{"servers":[{"type":"https","tag":"dns","server":"dns.invalid"}],"rules":[{"domain_suffix":["internal.test"],"server":"dns"}]},
      "inbounds":[{"type":"tun","tag":"original-tun","auto_route":true}],"experimental":{"cache_file":{"enabled":true}}
    }`
	parsed, err := parseSubscriptionWithFormat([]byte(content), "auto")
	if err != nil {
		t.Fatal(err)
	}
	s := nativeProviderTestProfile(t, parsed, "sing-box")
	if s.Name != "Профиль sing-box" || s.NodeCount != 3 || !reflect.DeepEqual(s.Protocols, []string{"vless", "hysteria2"}) || s.Protocol != "profile" {
		t.Fatal(s.ServerInfo)
	}
	var expected, got any
	json.Unmarshal([]byte(content), &expected)
	json.Unmarshal(s.Profile, &got)
	if !reflect.DeepEqual(expected, got) {
		t.Fatal("DNS, graph, order or unknown fields changed")
	}
	if s.ID != digest(string(s.Profile))[:24] {
		t.Fatal("ID is not canonical profile digest")
	}
	encoded, err := json.Marshal(s)
	if err != nil {
		t.Fatal(err)
	}
	var restored ServerConfig
	if json.Unmarshal(encoded, &restored) != nil || restored.SourceProfileCore != "sing-box" || !bytes.Equal(restored.Profile, s.Profile) || !reflect.DeepEqual(restored.Protocols, s.Protocols) {
		t.Fatal("native source/profile metadata not persistent")
	}
	if bytes.Contains([]byte(s.Name), []byte("private")) || strings.Contains(s.ID, "private") {
		t.Fatal("unsafe public metadata")
	}
}

func TestNativeProviderMihomoYAMLCanonicalAndScalarSemantics(t *testing.T) {
	const content = `# profile-title: native-title
proxies:
  - name: yes
    type: ss
    server: example.invalid
    port: 443
    password: "001234"
    cipher: aes-128-gcm
    udp: true
  - name: ON
    type: hy2
    password: |-
      private-password
      # this is password content, not metadata
  - {name: local, type: direct}
proxy-groups:
  - name: entry
    type: select
    proxies: [yes, ON, DIRECT]
rules:
  - DOMAIN,first.test,entry
  - MATCH,DIRECT
dns:
  enable: true
  enhanced-mode: fake-ip
  nameserver: [https://dns.invalid/dns-query]
proxy-providers:
  future:
    type: http
    url: https://private-provider.invalid/subscription-token
    interval: 3600
`
	parsed, err := parseSubscriptionWithFormat([]byte(content), "auto")
	if err != nil {
		t.Fatal(err)
	}
	s := nativeProviderTestProfile(t, parsed, "mihomo")
	if s.Name != "Профиль Mihomo" || s.NodeCount != 2 || !reflect.DeepEqual(s.Protocols, []string{"shadowsocks", "hysteria2"}) {
		t.Fatal(s.ServerInfo)
	}
	var profile object
	json.Unmarshal(s.Profile, &profile)
	proxies := profile["proxies"].([]any)
	if obj(proxies[0])["name"] != "yes" || obj(proxies[1])["name"] != "ON" || obj(proxies[0])["password"] != "001234" || obj(proxies[0])["udp"] != true || obj(proxies[0])["port"] != float64(443) {
		t.Fatal("YAML string/bool/number semantics changed")
	}
	if obj(proxies[1])["password"] != "private-password\n# this is password content, not metadata" {
		t.Fatal("YAML block scalar changed")
	}
	if profile["dns"] == nil || profile["proxy-providers"] == nil || !reflect.DeepEqual(profile["rules"], []any{"DOMAIN,first.test,entry", "MATCH,DIRECT"}) {
		t.Fatal("provider graph was flattened")
	}
	if parsed.MetadataHeaders.Get("profile-title") != "native-title" {
		t.Fatal("leading provider metadata lost")
	}
	// A JSON representation of that same graph has exactly the same persisted ID.
	again, err := parseSubscriptionWithFormat(s.Profile, "mihomo")
	if err != nil {
		t.Fatal(err)
	}
	if again.Servers[0].ID != s.ID || !bytes.Equal(again.Servers[0].Profile, s.Profile) {
		t.Fatal("canonical profile identity depends on YAML formatting")
	}
}

func TestNativeProviderLegacyCompatibilityAndExplicitFallback(t *testing.T) {
	uri := "vless://" + nativeTestUUID + "@example.invalid:443?security=tls#Legacy"
	node, err := parseServerURI(uri)
	if err != nil {
		t.Fatal(err)
	}
	profile := mustJSON(t, object{"outbounds": []any{json.RawMessage(node.Outbound), object{"protocol": "freedom", "tag": "direct"}}, "routing": object{"rules": []any{}}})
	for _, content := range [][]byte{[]byte(uri), []byte("# profile-title: title\n" + uri), []byte(base64.StdEncoding.EncodeToString([]byte(uri))), profile, []byte(base64.StdEncoding.EncodeToString(profile))} {
		legacy, err := parseSubscription(content)
		if err != nil {
			t.Fatal(err)
		}
		actual, err := parseSubscriptionWithFormat(content, "auto")
		if err != nil || !reflect.DeepEqual(legacy, actual) {
			t.Fatal("legacy auto parsing changed", err)
		}
		for _, requested := range []string{"sing-box", "mihomo"} {
			actual, err := parseSubscriptionWithFormat(content, requested)
			if err != nil {
				t.Fatal(err)
			}
			if actual.Servers[0].SourceProfileCore != "" || actual.Format != legacy.Format || len(actual.Warnings) != len(legacy.Warnings)+1 || !strings.Contains(actual.Warnings[0], "Провайдер не выдал ожидаемый формат") {
				t.Fatal("explicit fallback falsely labelled as native", actual)
			}
		}
	}
}

func TestNativeProviderBase64NativeAndEmptyNativeGraphs(t *testing.T) {
	for _, test := range []struct {
		content, core string
		nodes         int
	}{
		{`{"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}`, "sing-box", 0},
		{`{"proxies":[],"proxy-groups":[{"name":"entry","type":"select","proxies":["DIRECT"]}],"rules":["MATCH,entry"]}`, "mihomo", 0},
		{`{"proxy-providers":{"remote":{"type":"http","url":"https://private-provider.invalid/private-token"}}}`, "mihomo", 0},
		{`{"proxies":[{"type":"socks5","name":"local","server":"127.0.0.1","port":1080}]}`, "mihomo", 1},
	} {
		parsed, err := parseSubscriptionWithFormat([]byte(base64.StdEncoding.EncodeToString([]byte(test.content))), "auto")
		if err != nil {
			t.Fatal(err)
		}
		s := nativeProviderTestProfile(t, parsed, test.core)
		if s.NodeCount != test.nodes || !strings.Contains(parsed.Format, "Base64") {
			t.Fatal(s.ServerInfo, parsed.Format)
		}
	}
	parsed, err := parseSubscriptionWithFormat([]byte(`{"outbounds":[]}`), "sing-box")
	if err != nil || parsed.Servers[0].SourceProfileCore != "sing-box" {
		t.Fatal("explicit empty sing-box graph lost", err)
	}
}

func TestNativeProviderRejectsAmbiguousMalformedAndHTML(t *testing.T) {
	const secret = "do-not-echo-provider-password"
	cases := []string{
		`{"proxies":[],"outbounds":[{"type":"direct"}]}`,
		`{"outbounds":[{"type":"vless"},{"protocol":"vless"}]}`,
		`{"proxies":[],"outbounds":[{"protocol":"vless"}]}`,
		`{"outbounds":[]}`,
		`{"outbounds":[{"type":123}]}`,
		`{"proxies":{}}`, `{"proxy-groups":"bad"}`, `{"proxy-providers":[]}`, `{"proxy-providers":{"remote":null}}`, `{"proxies":[null]}`, `{"proxies":[{}]}`,
		`{"proxies":[{"type":"ss","password":"` + secret + `","password":"duplicate"}]}`,
		"proxies:\n  - type: ss\n    password: " + secret + "\n    password: duplicate\n",
		"proxies: &loop [*loop]", "proxies: [*missing]", "proxies: !custom []",
		"proxies: []\n1: " + secret, "proxies: []\n? [a,b]\n: value", "proxies: []\n<<: {}",
		"proxies: []\nvalue: !!binary c2VjcmV0", "proxies: []\nvalue: .nan", "proxies: []\nvalue: .inf",
		"proxies: []\nvalue: !!int 99999999999999999999999999999999999999999999999999999999",
		"proxies: []\n---\nproxies: []", "{\"proxies\":[]} trailing", "proxies: [",
		"<!doctype html><html>" + secret + "</html>", base64.StdEncoding.EncodeToString([]byte("<html>" + secret + "</html>")),
	}
	for i, content := range cases {
		_, err := parseSubscriptionWithFormat([]byte(content), "auto")
		var api apiError
		if !errors.As(err, &api) || api.status != 422 {
			t.Errorf("case %d accepted malformed native input: %v", i, err)
		}
		if err != nil && strings.Contains(err.Error(), secret) {
			t.Errorf("case %d leaked credentials", i)
		}
	}
	for _, test := range []struct{ content, format string }{{`{"proxies":[]}`, "sing-box"}, {`{"outbounds":[{"type":"direct"}]}`, "mihomo"}, {`{"proxies":[]}`, "unknown"}} {
		if _, err := parseSubscriptionWithFormat([]byte(test.content), test.format); err == nil {
			t.Fatal("format mismatch silently accepted")
		}
	}
}

func TestNativeProviderComplexityAndInputBounds(t *testing.T) {
	if _, err := parseSubscriptionWithFormat(bytes.Repeat([]byte(" "), nativeProviderMaxBytes+1), "auto"); err == nil {
		t.Fatal("oversize input accepted")
	}
	expanded := "proxies: []\nvalue: " + strings.Repeat("<", (nativeProviderMaxBytes/6)+1)
	if _, err := parseSubscriptionWithFormat([]byte(expanded), "auto"); err == nil {
		t.Fatal("oversize canonical profile accepted")
	}
	if _, err := parseSubscriptionWithFormat([]byte{'p', 'r', 'o', 'x', 'i', 'e', 's', ':', ' ', 0xff}, "auto"); err == nil {
		t.Fatal("non-UTF8 input accepted")
	}
	deep := `{"proxies":[],"nested":` + strings.Repeat("[", nativeProviderMaxDepth+2) + "null" + strings.Repeat("]", nativeProviderMaxDepth+2) + "}"
	if _, err := parseSubscriptionWithFormat([]byte(deep), "auto"); err == nil {
		t.Fatal("excessive nesting accepted")
	}
	many := `{"proxies":[],"nested":[` + strings.Repeat("null,", nativeProviderMaxNodes) + "null]}"
	if _, err := parseSubscriptionWithFormat([]byte(many), "auto"); err == nil {
		t.Fatal("excessive node count accepted")
	}
}

func TestNativeProviderProtocolMetadataIsBounded(t *testing.T) {
	for _, kind := range []string{"unsafe\nprivate-provider-password", strings.Repeat("a", 1000), "https://private-provider.invalid/token", "туик"} {
		content, _ := json.Marshal(object{"proxies": []any{object{"type": kind, "name": "provider node"}}})
		parsed, err := parseSubscriptionWithFormat(content, "mihomo")
		if err != nil {
			t.Fatal(err)
		}
		s := nativeProviderTestProfile(t, parsed, "mihomo")
		if !reflect.DeepEqual(s.Protocols, []string{"unknown"}) || s.Protocol != "unknown" || s.NodeCount != 1 {
			t.Fatal("unbounded provider type leaked into metadata")
		}
		var profile object
		json.Unmarshal(s.Profile, &profile)
		if obj(profile["proxies"].([]any)[0])["type"] != kind {
			t.Fatal("raw unsupported provider type changed")
		}
	}
}
