package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func nativeDirectDomainSources(t *testing.T, id string) map[string]ServerConfig {
	t.Helper()
	node := nativeTestServer(t)
	hy2, err := parseServerURI("hy2://fixture-password@example.invalid:443?sni=example.invalid")
	if err != nil {
		t.Fatal(err)
	}
	profile := nativeProfileTestSource(t)
	obj(profile["routing"])["rules"] = []any{object{"domain": []any{"domain:example.com"}, "outboundTag": "block"}}
	native := providerRuntimeFixture(id, 12345, "http://127.0.0.1:1/")
	if id == "sing-box" {
		outbounds := native["outbounds"].([]any)
		for _, tag := range []string{"svoi-sites-direct", "svoi-sites-direct-x"} {
			outbounds = append(outbounds, object{"type": "selector", "tag": tag, "outbounds": []any{"live"}})
		}
		native["outbounds"] = outbounds
	}
	result := map[string]ServerConfig{"node": node, "hysteria2-node": hy2, "xray-profile": nativeProfileTestServer(t, profile), "native-profile": providerRuntimeServer(t, id, native)}
	if id == "mihomo" {
		for _, mode := range []string{"global", "GLOBAL", "direct"} {
			p := providerRuntimeFixture(id, 12345, "http://127.0.0.1:1/")
			p["mode"] = mode
			result["native-"+mode] = providerRuntimeServer(t, id, p)
		}
	}
	return result
}

func TestNativeDirectDomainsPreserveGraphAndValidate(t *testing.T) {
	for _, id := range []string{"sing-box", "mihomo"} {
		t.Run(id, func(t *testing.T) {
			binary := testNativeCore(t, id)
			for name, server := range nativeDirectDomainSources(t, id) {
				t.Run(name, func(t *testing.T) {
					sourceProfile, sourceOutbound := bytes.Clone(server.Profile), bytes.Clone(server.Outbound)
					base, err := buildCoreConfig(id, server, 21081, 21082, "local")
					if err != nil {
						t.Fatal(err)
					}
					server.RuntimeDirectDomains = []string{" EXAMPLE.COM. ", "*.example.com", "example.net"}
					raw, err := buildCoreConfig(id, server, 21081, 21082, "local")
					if err != nil {
						t.Fatal(err)
					}
					if !bytes.Equal(sourceProfile, server.Profile) || !bytes.Equal(sourceOutbound, server.Outbound) {
						t.Fatal("stored credentials/profile mutated")
					}
					var before, after object
					json.Unmarshal(base, &before)
					json.Unmarshal(raw, &after)
					if id == "sing-box" {
						oldOuts, newOuts := before["outbounds"].([]any), after["outbounds"].([]any)
						if len(newOuts) != len(oldOuts)+1 || !reflect.DeepEqual(oldOuts, newOuts[:len(oldOuts)]) {
							t.Fatal("provider outbounds changed")
						}
						direct := obj(newOuts[len(oldOuts)])
						tag := str(direct["tag"])
						if direct["type"] != "direct" || len(direct) != 2 {
							t.Fatal("direct route inherited provider detour/options")
						}
						for _, out := range oldOuts {
							if obj(out)["tag"] == tag {
								t.Fatal("direct tag collision")
							}
						}
						oldRoute, newRoute := obj(before["route"]), obj(after["route"])
						newRules := newRoute["rules"].([]any)
						rule := obj(newRules[0])
						if rule["outbound"] != tag || rule["action"] != "route" || !reflect.DeepEqual(rule["domain_suffix"], []any{"example.com", "example.net"}) {
							t.Fatal(rule)
						}
						oldRules, _ := oldRoute["rules"].([]any)
						if len(newRules) != len(oldRules)+1 || !reflect.DeepEqual(newRules[1:], append([]any{}, oldRules...)) {
							t.Fatal("provider rule order changed")
						}
						delete(oldRoute, "rules")
						delete(newRoute, "rules")
						if !reflect.DeepEqual(oldRoute, newRoute) {
							t.Fatal("provider route defaults changed")
						}
					} else {
						for _, key := range []string{"proxies", "proxy-groups", "hosts", "dns"} {
							if !reflect.DeepEqual(before[key], after[key]) {
								t.Fatalf("provider %s changed", key)
							}
						}
						rules := after["rules"].([]any)
						if rules[0] != "DOMAIN-SUFFIX,example.com,DIRECT" || rules[1] != "DOMAIN-SUFFIX,example.net,DIRECT" {
							t.Fatal(rules)
						}
						prefix := 2
						if strings.EqualFold(str(before["mode"]), "global") {
							prefix++
							if after["mode"] != "rule" || rules[2] != "MATCH,GLOBAL" {
								t.Fatal("global fallback changed")
							}
						} else if after["mode"] != before["mode"] {
							t.Fatal("mode changed")
						}
						if !reflect.DeepEqual(rules[prefix:], before["rules"]) {
							t.Fatal("provider rules changed")
						}
					}
					dir := t.TempDir()
					path := filepath.Join(dir, "config.json")
					if err = os.WriteFile(path, raw, 0600); err != nil {
						t.Fatal(err)
					}
					cmd := exec.Command(binary, coreArgs(id, "check", path, dir)...)
					hideCommand(cmd)
					if out, err := cmd.CombinedOutput(); err != nil {
						t.Fatalf("actual native validation %v: %s", err, out)
					}
				})
			}
		})
	}
}

func TestNativeDirectDomainsRejectInvalidAndKeepAppRoutingUnsupported(t *testing.T) {
	for _, id := range []string{"sing-box", "mihomo"} {
		for name, server := range nativeDirectDomainSources(t, id) {
			t.Run(id+"/"+name, func(t *testing.T) {
				for _, bad := range []string{"localhost", "127.0.0.1", "https://example.com/path", "bad.com:443", "example.com,REJECT", "я.рф"} {
					server.RuntimeDirectDomains = []string{bad}
					if _, err := buildCoreConfig(id, server, 21081, 21082, "local"); err == nil {
						t.Fatalf("invalid domain accepted: %q", bad)
					}
				}
				server.RuntimeDirectDomains = []string{"example.com"}
				server.RuntimeApps = &AppRouting{Mode: "exclude", Processes: []string{"app.exe"}}
				if _, err := buildCoreConfig(id, server, 21081, 21082, "local"); err == nil {
					t.Fatal("unsupported application routing hidden by domain overlay")
				}
			})
		}
	}
}

func TestNativeDirectDomainsActualBypassAndSuffixBoundary(t *testing.T) {
	port, hits := nativeVLESSFixture(t)
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, "native-direct-domain-payload") }))
	defer target.Close()
	targetURL, _ := url.Parse(target.URL)
	for _, id := range []string{"sing-box", "mihomo"} {
		modes := []string{"rule"}
		if id == "mihomo" {
			modes = append(modes, "global")
		}
		for _, mode := range modes {
			t.Run(id+"/"+mode, func(t *testing.T) {
				profile := providerRuntimeFixture(id, port, target.URL)
				if id == "sing-box" {
					profile["outbounds"] = profile["outbounds"].([]any)[:3] // no background URL tests in the hit-count assertion
					// Resolve non-exempt destination names before the deliberately
					// IP-only local VLESS fixture; no system DNS or hosts changes.
					route := obj(profile["route"])
					route["rules"] = append([]any{object{"action": "resolve", "server": "hosts"}}, route["rules"].([]any)...)
					predefined := obj(obj(obj(profile["dns"])["servers"].([]any)[0])["predefined"])
					for _, domain := range []string{"blocked.invalid", "sub.blocked.invalid", "notblocked.invalid"} {
						predefined[domain] = []any{"127.0.0.1"}
					}
				} else {
					profile["proxy-groups"] = profile["proxy-groups"].([]any)[:1]
					profile["mode"] = mode
					if mode == "global" {
						profile["proxy-groups"] = append(profile["proxy-groups"].([]any), object{"name": "GLOBAL", "type": "select", "proxies": []any{"live"}})
					}
					for _, domain := range []string{"blocked.invalid", "sub.blocked.invalid", "notblocked.invalid"} {
						obj(profile["hosts"])[domain] = "127.0.0.1"
					}
				}
				server := providerRuntimeServer(t, id, profile)
				e := nativeTestEngine(t, id)
				e.checkURL = target.URL
				server.RuntimeDirectDomains = []string{" *.BLOCKED.INVALID. ", "blocked.invalid"}
				if err := e.Start(server, "local"); err != nil {
					t.Fatalf("start %v; %v", err, e.Status().Logs)
				}
				proxy, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", e.Status().HTTPPort))
				tr := &http.Transport{Proxy: http.ProxyURL(proxy), DisableKeepAlives: true}
				defer tr.CloseIdleConnections()
				client := &http.Client{Transport: tr, Timeout: 3 * time.Second}
				for _, domain := range []string{"blocked.invalid", "sub.blocked.invalid", "notblocked.invalid"} {
					before := hits.Load()
					response, err := client.Get("http://" + domain + ":" + targetURL.Port() + "/")
					if err != nil {
						t.Fatalf("%s: %v; %v", domain, err, e.Status().Logs)
					}
					body, _ := io.ReadAll(response.Body)
					response.Body.Close()
					if response.StatusCode != 200 || string(body) != "native-direct-domain-payload" {
						t.Fatalf("%s: %s %q; %v", domain, response.Status, body, e.Status().Logs)
					}
					proxied := hits.Load() > before
					if proxied != (domain == "notblocked.invalid") {
						t.Fatalf("suffix boundary/direct bypass incorrect for %s: proxied=%v", domain, proxied)
					}
				}
				if strings.Contains(strings.Join(e.Status().Logs, "\n"), "duplicate") {
					t.Fatal("tag collision")
				}
			})
		}
	}
}
