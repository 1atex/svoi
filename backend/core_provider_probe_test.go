package main

import (
	"bytes"
	"context"
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
	"sync/atomic"
	"testing"
	"time"
)

func providerNodeProbeFixture(t *testing.T, core string) ServerConfig {
	t.Helper()
	p := providerRuntimeFixture(core, 12345, "http://127.0.0.1:1/")
	if core == "sing-box" {
		p["outbounds"] = append(p["outbounds"].([]any), object{"type": "direct", "tag": "direct"})
		obj(p["route"])["rules"] = []any{object{"ip_cidr": []any{"127.0.0.0/8"}, "action": "route", "outbound": "direct"}}
	} else {
		p["rules"] = []any{"IP-CIDR,127.0.0.0/8,DIRECT,no-resolve", "MATCH,chosen"}
		p["rule-providers"] = object{"unused": object{"type": "http", "url": "https://example.invalid/unused-rules", "behavior": "domain", "format": "yaml"}}
	}
	server := providerRuntimeServer(t, core, p)
	server.NativeTarget = "live"
	server.ProfileNode = true
	return server
}

func TestNativeProviderNodeProbeDerivationPreservesSourceAndDNS(t *testing.T) {
	for _, core := range []string{"sing-box", "mihomo"} {
		t.Run(core, func(t *testing.T) {
			server := providerNodeProbeFixture(t, core)
			if core == "sing-box" {
				var profile object
				json.Unmarshal(server.Profile, &profile)
				obj(profile["route"])["auto_detect_interface"] = true
				server.Profile, _ = json.Marshal(profile)
			}
			server.RuntimeDirectDomains = []string{"example.com"}
			before := bytes.Clone(server.Profile)
			prepared, err := prepareProviderNodeProbe(server)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(before, server.Profile) || len(server.RuntimeDirectDomains) != 1 {
				t.Fatal("saved connection profile changed")
			}
			if len(prepared.RuntimeDirectDomains) != 0 || prepared.NativeTarget != "live" || !prepared.ProfileNode {
				t.Fatal("probe target/overlay incorrect")
			}
			var source, result object
			json.Unmarshal(before, &source)
			json.Unmarshal(prepared.Profile, &result)
			if !reflect.DeepEqual(source["dns"], result["dns"]) {
				t.Fatal("native DNS changed")
			}
			if result["rule-providers"] != nil || result["experimental"] != nil {
				t.Fatal("unrelated assets retained")
			}
			if core == "sing-box" && obj(result["route"])["auto_detect_interface"] != true {
				t.Fatal("outbound interface detection lost")
			}
			key, nameKey := "outbounds", "tag"
			if core == "mihomo" {
				key, nameKey = "proxies", "name"
			}
			for _, value := range result[key].([]any) {
				if name := str(obj(value)[nameKey]); name != "live" && name != "chosen" {
					t.Fatal("unrelated node/group retained")
				}
			}
			if _, err = buildCoreConfig(core, prepared, 21081, 21082, "local"); err != nil {
				t.Fatal(err)
			}
			server.NativeTarget = ""
			parent, err := prepareProviderNodeProbe(server)
			if err != nil || !reflect.DeepEqual(parent, server) {
				t.Fatal("parent profile probe changed")
			}
		})
	}
}

func TestNativeProviderNodeProbeDependencyClosure(t *testing.T) {
	for _, core := range []string{"sing-box", "mihomo"} {
		t.Run(core, func(t *testing.T) {
			server := providerNodeProbeFixture(t, core)
			var p object
			json.Unmarshal(server.Profile, &p)
			key, nameKey, dependency := "outbounds", "tag", "detour"
			if core == "mihomo" {
				key, nameKey, dependency = "proxies", "name", "dialer-proxy"
			}
			live := obj(p[key].([]any)[1])
			live[dependency] = "dependency"
			node := object{}
			for k, v := range live {
				node[k] = v
			}
			node[nameKey] = "dependency"
			delete(node, dependency)
			p[key] = append(p[key].([]any), node)
			server.Profile, _ = json.Marshal(p)
			prepared, err := prepareProviderNodeProbe(server)
			if err != nil {
				t.Fatal(err)
			}
			var result object
			json.Unmarshal(prepared.Profile, &result)
			found := false
			for _, value := range result[key].([]any) {
				if obj(value)[nameKey] == "dependency" {
					found = true
				}
			}
			if !found {
				t.Fatal("explicit node dependency dropped")
			}
			if core == "sing-box" {
				// A DNS detour through the primary selector must resolve to the
				// selected concrete node; legacy DNS default routing is the same.
				obj(obj(p["dns"])["servers"].([]any)[0])["detour"] = "chosen"
				server.Profile, _ = json.Marshal(p)
				if _, err = prepareProviderNodeProbe(server); err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}

func TestNativeProviderNodeProbeRejectsAmbiguousDependencies(t *testing.T) {
	for _, core := range []string{"sing-box", "mihomo"} {
		key, dependency := "outbounds", "detour"
		if core == "mihomo" {
			key, dependency = "proxies", "dialer-proxy"
		}
		for _, kind := range []string{"missing-target", "missing-dependency", "cycle", "dynamic-group", "duplicate", "dns-rule-set"} {
			t.Run(core+"/"+kind, func(t *testing.T) {
				server := providerNodeProbeFixture(t, core)
				var p object
				json.Unmarshal(server.Profile, &p)
				nodes := p[key].([]any)
				live := obj(nodes[1])
				switch kind {
				case "missing-target":
					server.NativeTarget = "absent"
				case "missing-dependency":
					live[dependency] = "absent"
				case "cycle":
					live[dependency] = "chosen"
				case "dynamic-group":
					live[dependency] = "automatic"
				case "duplicate":
					p[key] = append(nodes, live)
				case "dns-rule-set":
					if core == "sing-box" {
						obj(p["dns"])["rules"] = []any{object{"rule_set": []any{"remote"}, "server": "hosts"}}
					} else {
						obj(p["dns"])["fake-ip-filter"] = []any{"RULE-SET,unused,real-ip"}
						obj(p["dns"])["fake-ip-filter-mode"] = "rule"
					}
				}
				server.Profile, _ = json.Marshal(p)
				if _, err := prepareProviderNodeProbe(server); err == nil {
					t.Fatal("unsafe/ambiguous node probe accepted")
				}
			})
		}
	}
}

func TestNativeProviderNodeProbeDependencyGroupOptions(t *testing.T) {
	server := providerNodeProbeFixture(t, "mihomo")
	var profile object
	json.Unmarshal(server.Profile, &profile)
	obj(profile["proxies"].([]any)[1])["dialer-proxy"] = "dependency-group"
	profile["proxy-groups"] = append(profile["proxy-groups"].([]any), object{"type": "select", "name": "dependency-group", "proxies": []any{"dead"}, "disable-udp": true})
	server.Profile, _ = json.Marshal(profile)
	prepared, err := prepareProviderNodeProbe(server)
	if err != nil {
		t.Fatal(err)
	}
	var result object
	json.Unmarshal(prepared.Profile, &result)
	found := false
	for _, value := range result["proxy-groups"].([]any) {
		group := obj(value)
		if group["name"] == "dependency-group" {
			found = true
			if group["disable-udp"] != true {
				t.Fatal("dependency UDP restriction lost")
			}
		}
	}
	if !found {
		t.Fatal("dependency group lost")
	}
	group := obj(profile["proxy-groups"].([]any)[2])
	group["exclude-filter"] = ".*"
	server.Profile, _ = json.Marshal(profile)
	if _, err = prepareProviderNodeProbe(server); err == nil {
		t.Fatal("filtered dependency group could silently fall back DIRECT")
	}
}

func TestNativeProviderNodeProbeForcesSelectedNodeWithoutRuleDownloads(t *testing.T) {
	var assetRequests atomic.Int32
	assets := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assetRequests.Add(1)
		_, _ = io.WriteString(w, "payload:\n  - example.invalid\n")
	}))
	defer assets.Close()
	port, hits := nativeVLESSFixture(t)
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "selected-native-node-sentinel")
	}))
	defer target.Close()
	for _, core := range []string{"sing-box", "mihomo"} {
		t.Run(core, func(t *testing.T) {
			server := providerNodeProbeFixture(t, core)
			var p object
			json.Unmarshal(server.Profile, &p)
			key := "outbounds"
			if core == "mihomo" {
				key = "proxies"
			}
			live := obj(p[key].([]any)[1])
			portKey := "server_port"
			if core == "mihomo" {
				portKey = "port"
			}
			live[portKey] = port
			if core == "mihomo" {
				obj(obj(p["rule-providers"])["unused"])["url"] = assets.URL + "/rules"
				obj(p["proxy-groups"].([]any)[1])["url"] = assets.URL + "/health"
			} else {
				obj(p["outbounds"].([]any)[3])["url"] = assets.URL + "/health"
			}
			server.Profile, _ = json.Marshal(p)
			original := bytes.Clone(server.Profile)
			for _, selection := range []string{"dead", "live"} {
				t.Run(selection, func(t *testing.T) {
					selected := server
					selected.NativeTarget = selection
					prepared, err := prepareProviderNodeProbe(selected)
					if err != nil {
						t.Fatal(err)
					}
					e := nativeTestEngine(t, core)
					e.checkURL = target.URL
					if err = e.Start(prepared, "local"); err != nil {
						t.Fatalf("start: %v; %v", err, e.Status().Logs)
					}
					proxy, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", e.Status().HTTPPort))
					tr := &http.Transport{Proxy: http.ProxyURL(proxy), DisableKeepAlives: true}
					defer tr.CloseIdleConnections()
					client := &http.Client{Transport: tr, Timeout: time.Second}
					before := hits.Load()
					response, err := client.Get(target.URL)
					if selection == "dead" {
						if err == nil {
							response.Body.Close()
							if response.StatusCode < 400 {
								t.Fatal("dead selected node falsely succeeded through provider DIRECT rule")
							}
						}
					} else {
						if err != nil {
							t.Fatal(err)
						}
						body, _ := io.ReadAll(response.Body)
						response.Body.Close()
						if response.StatusCode != 200 || string(body) != "selected-native-node-sentinel" || hits.Load() <= before {
							t.Fatal("selected live node did not carry sentinel")
						}
					}
					if assetRequests.Load() != 0 {
						t.Fatal("node probe downloaded unrelated rules or ran automatic group checks")
					}
				})
			}
			if !bytes.Equal(original, server.Profile) {
				t.Fatal("actual connection profile modified")
			}
		})
	}
}

func TestNativeProviderNodeProbePipeline(t *testing.T) {
	// Exercise the public probe path with an unprepared virtual row. Its target
	// must be measured even when the full profile allows DIRECT.
	port, _ := nativeVLESSFixture(t)
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	defer target.Close()
	for _, core := range []string{"sing-box", "mihomo"} {
		t.Run(core, func(t *testing.T) {
			server := providerNodeProbeFixture(t, core)
			var p object
			json.Unmarshal(server.Profile, &p)
			key, portKey := "outbounds", "server_port"
			if core == "mihomo" {
				key, portKey = "proxies", "port"
			}
			obj(p[key].([]any)[1])[portKey] = port
			server.Profile, _ = json.Marshal(p)
			e := nativeTestEngine(t, core)
			for _, selection := range []string{"dead", "live"} {
				server.NativeTarget = selection
				_, err := probeServer(context.Background(), e, server, ProbeSettings{URL: target.URL, TimeoutSeconds: 2, Parallel: 1})
				if selection == "dead" && err == nil {
					t.Fatal("probeServer falsely succeeded through provider DIRECT rule")
				}
				if selection == "live" && err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}

// Private opt-in validation never starts a provider connection and suppresses
// native output. All virtual rows are derived; one per protocol is core-checked.
func TestNativeProviderNodeProbePrivateConfigChecks(t *testing.T) {
	for _, fixture := range []struct{ core, env string }{{"sing-box", "SVOI_TEST_PRIVATE_SING_BOX_PROFILE"}, {"mihomo", "SVOI_TEST_PRIVATE_MIHOMO_PROFILE"}} {
		t.Run(fixture.core, func(t *testing.T) {
			path := os.Getenv(fixture.env)
			if path == "" {
				t.Skip("private provider fixture is opt-in")
			}
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal("cannot read private provider fixture")
			}
			value, err := nativeProviderDocument(data)
			if err != nil {
				t.Fatal("cannot parse private provider fixture")
			}
			profile, ok := value.(map[string]any)
			if !ok {
				t.Fatal("private provider is not an object")
			}
			server := providerRuntimeServer(t, fixture.core, profile)
			source := bytes.Clone(server.Profile)
			nodes := providerSelectableNodes(fixture.core, profile)
			if len(nodes) == 0 {
				t.Fatal("no selectable private nodes")
			}
			checked := map[string]bool{}
			for _, node := range nodes {
				nameKey := "tag"
				if fixture.core == "mihomo" {
					nameKey = "name"
				}
				server.NativeTarget = str(node[nameKey])
				prepared, err := prepareProviderNodeProbe(server)
				if err != nil {
					t.Fatal(err)
				}
				var derived object
				json.Unmarshal(prepared.Profile, &derived)
				if derived["rule-providers"] != nil {
					t.Fatal("private node retained remote providers")
				}
				if fixture.core == "mihomo" {
					for _, key := range []string{"nameserver-policy", "enhanced-mode", "fake-ip-range", "fake-ip-filter"} {
						if !reflect.DeepEqual(obj(profile["dns"])[key], obj(derived["dns"])[key]) {
							t.Fatal("private Mihomo DNS dependency changed")
						}
					}
				}
				protocol := str(node["type"])
				if checked[protocol] {
					continue
				}
				checked[protocol] = true
				raw, err := buildCoreConfig(fixture.core, prepared, 21081, 21082, "local")
				if err != nil {
					t.Fatal(err)
				}
				dir := t.TempDir()
				config := filepath.Join(dir, "private-node.json")
				if err = os.WriteFile(config, raw, 0600); err != nil {
					t.Fatal("cannot write isolated private check")
				}
				cmd := exec.Command(testNativeCore(t, fixture.core), coreArgs(fixture.core, "check", config, dir)...)
				hideCommand(cmd)
				cmd.Dir = dir
				cmd.Env = coreEnvironment(fixture.core)
				if _, err = cmd.CombinedOutput(); err != nil {
					t.Fatal("private prepared node failed native check; sensitive output suppressed")
				}
			}
			if !bytes.Equal(source, server.Profile) {
				t.Fatal("private saved profile mutated")
			}
			t.Logf("prepared %d private node views; actual native checks passed for %d protocol types", len(nodes), len(checked))
		})
	}
}
