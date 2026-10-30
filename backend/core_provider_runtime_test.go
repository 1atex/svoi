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
	"runtime"
	"testing"
	"time"
)

func providerRuntimeFixture(id string, port int, checkURL string) object {
	if id == "sing-box" {
		return object{
			"inbounds":     []any{object{"type": "mixed", "tag": "provider-in", "listen": "0.0.0.0", "listen_port": 9999}},
			"experimental": object{"cache_file": object{"enabled": true, "path": "provider-cache.db"}, "clash_api": object{"external_controller": "0.0.0.0:9090"}},
			"outbounds": []any{
				object{"type": "vless", "tag": "dead", "server": "127.0.0.1", "server_port": 1, "uuid": nativeTestUUID},
				object{"type": "vless", "tag": "live", "server": "fixture.invalid", "server_port": port, "uuid": nativeTestUUID, "domain_resolver": "hosts"},
				object{"type": "selector", "tag": "chosen", "outbounds": []any{"dead", "live"}, "default": "live"},
				object{"type": "urltest", "tag": "automatic", "outbounds": []any{"live"}, "url": checkURL, "interval": "10m"},
			},
			"dns":   object{"servers": []any{object{"type": "hosts", "tag": "hosts", "predefined": object{"fixture.invalid": []any{"127.0.0.1"}}}}, "final": "hosts"},
			"route": object{"rules": []any{object{"action": "sniff", "sniffer": []any{"http", "tls"}, "timeout": "100ms"}, object{"domain": []any{"blocked.invalid"}, "action": "reject"}}, "final": "chosen"},
		}
	}
	return object{
		"mixed-port": 9999, "allow-lan": true, "external-controller": "0.0.0.0:9090", "external-ui": "provider-ui", "secret": "fixture-secret", "tun": object{"enable": true},
		"mode": "rule", "hosts": object{"fixture.invalid": "127.0.0.1"},
		"dns":          object{"enable": true, "use-hosts": true, "use-system-hosts": false, "nameserver": []any{"127.0.0.1:1"}},
		"sniffer":      object{"enable": true, "parse-pure-ip": false, "override-destination": false, "sniff": object{"HTTP": object{"ports": []any{80, 8080}}}},
		"proxies":      []any{object{"type": "vless", "name": "dead", "server": "127.0.0.1", "port": 1, "uuid": nativeTestUUID, "udp": true}, object{"type": "vless", "name": "live", "server": "fixture.invalid", "port": port, "uuid": nativeTestUUID, "udp": true}},
		"proxy-groups": []any{object{"type": "select", "name": "chosen", "proxies": []any{"live", "dead"}}, object{"type": "url-test", "name": "automatic", "proxies": []any{"live"}, "url": checkURL, "interval": 600}},
		"rules":        []any{"DOMAIN,blocked.invalid,REJECT", "MATCH,chosen"},
	}
}

func providerRuntimeServer(t *testing.T, id string, profile object) ServerConfig {
	t.Helper()
	raw, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	return ServerConfig{ServerInfo: ServerInfo{SourceProfileCore: id, FullProfile: true}, Profile: raw}
}

func TestNativeProviderRuntimeConfigChecks(t *testing.T) {
	for _, id := range []string{"sing-box", "mihomo"} {
		t.Run(id, func(t *testing.T) {
			binary := testNativeCore(t, id)
			profile := providerRuntimeFixture(id, 12345, "http://127.0.0.1:1/")
			if id == "mihomo" {
				dns := obj(profile["dns"])
				dns["fallback"] = []any{"127.0.0.1:2"}
				dns["fallback-filter"] = object{"geoip": false, "geoip-code": "CN", "geosite": []any{}, "ipcidr": []any{"240.0.0.0/4"}}
			}
			server := providerRuntimeServer(t, id, profile)
			source := append([]byte(nil), server.Profile...)
			data, err := buildCoreConfig(id, server, 10808, 10809, "local")
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(source, server.Profile) {
				t.Fatal("source profile mutated")
			}
			var result object
			if err = json.Unmarshal(data, &result); err != nil {
				t.Fatal(err)
			}
			keys := []string{"outbounds", "route", "dns"}
			if id == "mihomo" {
				keys = []string{"proxies", "proxy-groups", "rules", "dns", "hosts", "sniffer", "mode"}
			}
			for _, key := range keys {
				var original any
				b, _ := json.Marshal(profile[key])
				_ = json.Unmarshal(b, &original)
				if !reflect.DeepEqual(original, result[key]) {
					t.Fatalf("provider graph changed: %s", key)
				}
			}
			if id == "sing-box" {
				if result["experimental"] != nil {
					t.Fatal("provider management/cache retained")
				}
				for _, inbound := range result["inbounds"].([]any) {
					if obj(inbound)["listen"] != "127.0.0.1" {
						t.Fatal("public listener")
					}
				}
			} else {
				for _, key := range []string{"mixed-port", "external-controller", "external-ui", "secret", "tun"} {
					if result[key] != nil {
						t.Fatalf("unsafe control plane %s", key)
					}
				}
				if result["allow-lan"] != false || result["bind-address"] != "127.0.0.1" {
					t.Fatal("public listener")
				}
			}
			dir := t.TempDir()
			path := filepath.Join(dir, "config.json")
			if err = os.WriteFile(path, data, 0600); err != nil {
				t.Fatal(err)
			}
			cmd := exec.Command(binary, coreArgs(id, "check", path, dir)...)
			hideCommand(cmd)
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("native check %v: %s", err, out)
			}
		})
	}
}

func TestNativeProviderRuntimeRejectsUnsafeSemantics(t *testing.T) {
	for _, id := range []string{"sing-box", "mihomo"} {
		cases := map[string]func(object){"unknown-top": func(p object) { p["future-unsafe"] = true }}
		if id == "sing-box" {
			cases["endpoint"] = func(p object) { p["endpoints"] = []any{object{"type": "wireguard"}} }
			cases["rule-set"] = func(p object) {
				obj(p["route"])["rule_set"] = []any{object{"type": "remote", "url": "https://example.invalid/rules"}}
			}
			cases["inbound-rule"] = func(p object) {
				obj(p["route"])["rules"] = []any{object{"inbound": []any{"provider-in"}, "outbound": "live"}}
			}
			cases["inbound-sniff"] = func(p object) { obj(p["inbounds"].([]any)[0])["sniff"] = true }
			cases["certificate-file"] = func(p object) {
				obj(p["outbounds"].([]any)[1])["tls"] = object{"enabled": true, "certificate_path": "secret.pem"}
			}
			cases["ech-config-file"] = func(p object) {
				obj(p["outbounds"].([]any)[1])["tls"] = object{"enabled": true, "ech": object{"enabled": true, "config_path": "secret-ech.pem"}}
			}
			cases["client-key-file"] = func(p object) {
				obj(p["outbounds"].([]any)[1])["tls"] = object{"enabled": true, "client_key_path": "secret-key.pem"}
			}
			cases["source-port-rule"] = func(p object) {
				obj(p["route"])["rules"] = []any{object{"source_port": []any{9999}, "outbound": "live"}}
			}
			cases["forwarding-inbound"] = func(p object) {
				p["inbounds"] = []any{object{"type": "direct", "listen_port": 9999, "override_address": "example.invalid", "override_port": 80}}
			}
			cases["hosts-file"] = func(p object) { obj(obj(p["dns"])["servers"].([]any)[0])["path"] = []any{"hosts.txt"} }
			cases["os-interface"] = func(p object) { obj(p["outbounds"].([]any)[1])["bind_interface"] = "eth0" }
			cases["dns-listen"] = func(p object) { obj(p["dns"])["listen"] = "0.0.0.0:53" }
		} else {
			cases["proxy-provider"] = func(p object) {
				p["proxy-providers"] = object{"remote": object{"url": "https://example.invalid/provider"}}
			}
			cases["file-rule-provider"] = func(p object) {
				p["rule-providers"] = object{"local": object{"type": "file", "path": "secret.txt", "behavior": "domain"}}
			}
			cases["group-use-provider"] = func(p object) { obj(p["proxy-groups"].([]any)[0])["use"] = []any{"remote"} }
			cases["geodata"] = func(p object) { p["rules"] = []any{"GEOIP,CN,DIRECT"} }
			cases["nested-geodata"] = func(p object) { p["rules"] = []any{"AND,((NETWORK,TCP),(GEOSITE,cn)),DIRECT"} }
			cases["inbound-rule"] = func(p object) { p["rules"] = []any{"IN-NAME,provider,chosen"} }
			cases["certificate-file"] = func(p object) { obj(p["proxies"].([]any)[1])["certificate"] = "secret.pem" }
			cases["ssh"] = func(p object) { obj(p["proxies"].([]any)[1])["type"] = "ssh" }
			cases["os-interface"] = func(p object) { obj(p["proxies"].([]any)[1])["interface-name"] = "eth0" }
			cases["dns-listen"] = func(p object) { obj(p["dns"])["listen"] = "0.0.0.0:53" }
			cases["script"] = func(p object) { p["script"] = object{"code": "unsafe"} }
			cases["dns-geosite"] = func(p object) { obj(p["dns"])["nameserver-policy"] = object{"geosite:cn": []any{"1.1.1.1"}} }
			cases["dns-fallback-implicit-geoip"] = func(p object) { obj(p["dns"])["fallback"] = []any{"127.0.0.1:1"} }
			cases["dns-fake-ip-geosite"] = func(p object) { obj(p["dns"])["fake-ip-filter"] = []any{"geosite:cn"} }
			cases["forwarding-tunnel"] = func(p object) { p["tunnels"] = []any{"tcp,127.0.0.1:9999,example.invalid:80,chosen"} }
			cases["forced-listener-proxy"] = func(p object) {
				p["listeners"] = []any{object{"type": "mixed", "name": "provider", "port": 9999, "proxy": "chosen"}}
			}
			cases["source-port-rule"] = func(p object) { p["rules"] = []any{"SRC-PORT,9999,chosen"} }
		}
		for name, edit := range cases {
			t.Run(id+"/"+name, func(t *testing.T) {
				p := providerRuntimeFixture(id, 12345, "http://127.0.0.1:1/")
				edit(p)
				server := providerRuntimeServer(t, id, p)
				if _, err := buildCoreConfig(id, server, 10808, 10809, "local"); err == nil {
					t.Fatal("unsafe profile accepted")
				}
			})
		}
		server := providerRuntimeServer(t, id, providerRuntimeFixture(id, 12345, "http://127.0.0.1:1/"))
		if _, err := buildCoreConfig(id, server, 10808, 10809, "tun"); (err == nil) != (runtime.GOOS == "windows") {
			t.Fatalf("unexpected TUN support: %v", err)
		}
		other := "mihomo"
		if id == other {
			other = "sing-box"
		}
		if _, err := buildCoreConfig(other, server, 10808, 10809, "local"); err == nil {
			t.Fatal("mismatched source accepted")
		}
	}
}

func providerRuntimeVLESS(t *testing.T) int {
	t.Helper()
	listener, udp, port, err := reserveSocksPort()
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	defer udp.Close()
	config := object{"log": object{"loglevel": "warning"}, "inbounds": []any{object{"listen": "127.0.0.1", "port": port, "protocol": "vless", "settings": object{"clients": []any{object{"id": nativeTestUUID}}, "decryption": "none"}}}, "outbounds": []any{object{"protocol": "freedom", "settings": object{"finalRules": []any{object{"action": "allow", "ip": []any{"127.0.0.1"}}}}}}}
	data, _ := json.Marshal(config)
	path := filepath.Join(t.TempDir(), "server.json")
	if err = os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	logs := &Engine{}
	cmd := exec.Command(testCore(t), "run", "-c", path)
	hideCommand(cmd)
	cmd.Stdout, cmd.Stderr = logs, logs
	listener.Close()
	udp.Close()
	if err = cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		if t.Failed() {
			t.Log(logs.Status().Logs)
		}
	})
	deadline := time.Now().Add(5 * time.Second)
	for {
		logs.mu.Lock()
		ready := logs.coreStarted
		logs.mu.Unlock()
		if ready {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("local VLESS fixture startup")
		}
		time.Sleep(20 * time.Millisecond)
	}
	return port
}

func TestNativeProviderRuntimeWholeGraphRoundTrip(t *testing.T) {
	port := providerRuntimeVLESS(t)
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "provider-whole-graph-loopback")
	}))
	defer target.Close()
	for _, id := range []string{"sing-box", "mihomo"} {
		t.Run(id, func(t *testing.T) {
			profile := providerRuntimeFixture(id, port, target.URL)
			raw, err := json.Marshal(profile)
			if err != nil {
				t.Fatal(err)
			}
			parsed, err := parseSubscriptionWithFormat(raw, id)
			if err != nil {
				t.Fatal(err)
			}
			if len(parsed.Servers) != 1 || parsed.Servers[0].SourceProfileCore != id {
				t.Fatal("native import must retain exactly one bound whole profile")
			}
			server := parsed.Servers[0]
			source := append([]byte(nil), server.Profile...)
			e := nativeTestEngine(t, id)
			e.checkURL = target.URL
			if err := e.Start(server, "local"); err != nil {
				t.Fatalf("start: %v; %v", err, e.Status().Logs)
			}
			if _, err := e.Check(context.Background()); err != nil {
				t.Fatalf("native graph health: %v; %v", err, e.Status().Logs)
			}
			proxy, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", e.Status().HTTPPort))
			tr := &http.Transport{Proxy: http.ProxyURL(proxy), DisableKeepAlives: true}
			defer tr.CloseIdleConnections()
			client := &http.Client{Transport: tr, Timeout: 3 * time.Second}
			response, err := client.Get(target.URL)
			if err != nil {
				t.Fatal(err)
			}
			body, _ := io.ReadAll(response.Body)
			response.Body.Close()
			if response.StatusCode != 200 || string(body) != "provider-whole-graph-loopback" {
				t.Fatalf("unexpected proxy payload %s %q; %v", response.Status, body, e.Status().Logs)
			}
			// The earlier reject rule must win over the final selected live proxy.
			response, err = client.Get("http://blocked.invalid/")
			if err == nil {
				response.Body.Close()
				if response.StatusCode < 400 {
					t.Fatal("rule order/reject lost")
				}
			}
			testHysteriaUDP(t, e.Status().SocksPort)
			if !bytes.Equal(source, server.Profile) {
				t.Fatal("source profile mutated at runtime")
			}
		})
	}
}
