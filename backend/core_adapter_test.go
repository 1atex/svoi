package main

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const nativeTestUUID = "90e3da82-374e-46ef-9099-761d39b86b82"

func TestSubscriptionCoreBinding(t *testing.T) {
	for _, source := range []string{"xray", "sing-box", "mihomo"} {
		server := nativeTestServer(t)
		server.SubscriptionCore, server.FullProfile = source, true
		for _, core := range []string{"xray", "sing-box", "mihomo"} {
			if core == source {
				continue
			}
			_, err := buildCoreConfig(core, server, 10808, 10809, "local")
			if err == nil || !strings.Contains(err.Error(), "Ядро изменилось") {
				t.Fatalf("scope %s executed on %s: %v", source, core, err)
			}
		}
	}
	server := nativeTestServer(t)
	server.SubscriptionCore = "xray"
	for _, core := range []string{"sing-box", "mihomo"} {
		server.RuntimeFallbackCore = ""
		if _, err := buildCoreConfig(core, server, 10808, 10809, "local"); err == nil {
			t.Fatal("unbound fallback accepted")
		}
		server.RuntimeFallbackCore = core
		if _, err := buildCoreConfig(core, server, 10808, 10809, "local"); err != nil {
			t.Fatalf("standalone legacy fallback %s: %v", core, err)
		}
	}
}

func TestSubscriptionFallbackBindingRequiresUnavailableVariant(t *testing.T) {
	server := nativeTestServer(t)
	server.SubscriptionCore, server.SubscriptionID = "xray", "source"
	for _, status := range []SubscriptionVariantStatus{{State: "ready"}, {State: "error"}, {State: "unavailable", Count: 1}, {State: "unavailable"}} {
		g := &Group{Subscriptions: []Subscription{{ID: "source", Variants: map[string]SubscriptionVariantStatus{"mihomo": status}}}}
		bound := bindSubscriptionFallback(g, "mihomo", server)
		want := status.State == "unavailable" && status.Count == 0
		if (bound.RuntimeFallbackCore == "mihomo") != want {
			t.Fatalf("wrong binding for %#v", status)
		}
		if _, err := buildCoreConfig("sing-box", bound, 10808, 10809, "local"); err == nil {
			t.Fatal("fallback binding crossed core switch")
		}
	}
}

func TestNativeProviderCoreBinding(t *testing.T) {
	for _, source := range []string{"sing-box", "mihomo", "unrecognized"} {
		server := ServerConfig{ServerInfo: ServerInfo{SourceProfileCore: source, FullProfile: true}, Profile: json.RawMessage(`{}`)}
		for _, selected := range []string{"", "xray", "sing-box", "mihomo"} {
			if source == selected {
				continue
			}
			if _, err := buildCoreConfig(selected, server, 10808, 10809, "local"); err == nil {
				t.Fatalf("native %s profile accepted by %s", source, selected)
			}
		}
	}
}

func testNativeCore(t *testing.T, id string) string {
	t.Helper()
	env := "SVOI_TEST_" + strings.ToUpper(strings.ReplaceAll(id, "-", "_"))
	path := os.Getenv(env)
	if path == "" {
		name := id
		if runtime.GOOS == "windows" {
			name += ".exe"
		}
		path = filepath.Join("..", "core", name)
	}
	path, err := filepath.Abs(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = os.Stat(path); err != nil {
		t.Skip("optional core unavailable; set " + env)
	}
	return path
}
func nativeTestEngine(t *testing.T, id string) *Engine {
	t.Helper()
	binary := testNativeCore(t, id)
	name := "xray"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	e, err := newEngine(filepath.Join(filepath.Dir(binary), name), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err = e.SelectCore(id); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := e.Stop(); err != nil {
			t.Error(err)
		}
	})
	return e
}
func nativeTestServer(t *testing.T) ServerConfig {
	t.Helper()
	s, err := parseServerURI("vless://" + nativeTestUUID + "@example.com:443?security=tls&type=ws&path=%2Fsvoi&host=example.com")
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestNativeCoreRejectsLossyConversions(t *testing.T) {
	edits := map[string]func(*ServerConfig, object){
		"full-profile":      func(s *ServerConfig, _ object) { s.Profile = json.RawMessage(`{"outbounds":[]}`) },
		"full-profile-flag": func(s *ServerConfig, _ object) { s.FullProfile = true },
		"app-routing": func(s *ServerConfig, _ object) {
			s.RuntimeApps = &AppRouting{Mode: "exclude", Processes: []string{"app.exe"}}
		},
		"mux":               func(_ *ServerConfig, o object) { o["mux"] = object{"enabled": true} },
		"chain":             func(_ *ServerConfig, o object) { o["proxySettings"] = object{"tag": "other"} },
		"unknown-security":  func(_ *ServerConfig, o object) { obj(o["streamSettings"])["security"] = "xtls" },
		"security-type":     func(_ *ServerConfig, o object) { obj(o["streamSettings"])["security"] = true },
		"unknown-transport": func(_ *ServerConfig, o object) { obj(o["streamSettings"])["network"] = "xhttp" },
		"unknown-option":    func(_ *ServerConfig, o object) { obj(o["streamSettings"])["sockopt"] = object{"mark": 10} },
		"tls-certificate": func(_ *ServerConfig, o object) {
			obj(obj(o["streamSettings"])["tlsSettings"])["pinnedPeerCertificateChainSha256"] = []any{"hash"}
		},
		"ws-early-data":      func(_ *ServerConfig, o object) { obj(obj(o["streamSettings"])["wsSettings"])["maxEarlyData"] = 2048 },
		"ws-early-data-path": func(_ *ServerConfig, o object) { obj(obj(o["streamSettings"])["wsSettings"])["path"] = "/?ed=2048" },
		"grpc-multi": func(_ *ServerConfig, o object) {
			o["streamSettings"] = object{"network": "grpc", "grpcSettings": object{"multiMode": true}}
		},
		"tcp-header": func(_ *ServerConfig, o object) {
			o["streamSettings"] = object{"network": "tcp", "tcpSettings": object{"header": object{"type": "http"}}}
		},
		"extra-user": func(_ *ServerConfig, o object) {
			endpoint := firstObject(obj(o["settings"])["vnext"])
			endpoint["users"] = append(endpoint["users"].([]any), object{"id": nativeTestUUID})
		},
		"vless-encryption": func(_ *ServerConfig, o object) {
			firstObject(firstObject(obj(o["settings"])["vnext"])["users"])["encryption"] = "new-encryption"
		},
	}
	for _, id := range []string{"sing-box", "mihomo"} {
		for name, edit := range edits {
			t.Run(id+"/"+name, func(t *testing.T) {
				s := nativeTestServer(t)
				var o object
				_ = json.Unmarshal(s.Outbound, &o)
				edit(&s, o)
				s.Outbound, _ = json.Marshal(o)
				if _, err := buildCoreConfig(id, s, 10808, 10809, "local"); err == nil {
					t.Fatal("unsupported settings silently accepted")
				}
			})
		}
		if _, err := buildCoreConfig(id, nativeTestServer(t), 10808, 10809, "tun"); (err == nil) != (runtime.GOOS == "windows") {
			t.Fatalf("unexpected TUN support: %v", err)
		}
	}
}

func TestNativeCoreConfigValidation(t *testing.T) {
	vmess := func(network string) string {
		b, _ := json.Marshal(object{"v": "2", "ps": network, "add": "example.com", "port": "443", "id": nativeTestUUID, "aid": "0", "net": network, "path": "/svoi", "host": "example.com", "tls": "tls", "sni": "example.com"})
		return "vmess://" + base64.StdEncoding.EncodeToString(b)
	}
	cases := []string{
		"vless://" + nativeTestUUID + "@example.com:443?security=tls&type=tcp#vless-tcp-tls",
		"vless://" + nativeTestUUID + "@example.com:443?security=tls&type=ws&path=%2Fsvoi&host=example.com#vless-ws-tls",
		"vless://" + nativeTestUUID + "@example.com:443?security=tls&type=grpc&serviceName=svoi#vless-grpc-tls",
		"vless://" + nativeTestUUID + "@example.com:443?security=reality&sni=example.com&pbk=FbzRLPlQIpk7z1rfW4mG0mFBQ9LB9nc8LmGvzKDSRCE&sid=abcd&flow=xtls-rprx-vision#vless-reality",
		vmess("tcp"), vmess("ws"), vmess("grpc"),
		"trojan://test-password@example.com:443?sni=example.com#trojan-tcp",
		"trojan://test-password@example.com:443?sni=example.com&type=ws&path=%2Fsvoi#trojan-ws",
		"trojan://test-password@example.com:443?sni=example.com&type=grpc&serviceName=svoi#trojan-grpc",
		"ss://" + base64.RawURLEncoding.EncodeToString([]byte("aes-128-gcm:test-password")) + "@example.com:8388#ss-tcp",
	}
	for _, id := range []string{"sing-box", "mihomo"} {
		t.Run(id, func(t *testing.T) {
			binaryPath := testNativeCore(t, id)
			for _, uri := range cases {
				s, err := parseServerURI(uri)
				if err != nil {
					t.Fatal(err)
				}
				t.Run(s.Name, func(t *testing.T) {
					raw, err := buildCoreConfig(id, s, 21081, 21082, "local")
					if err != nil {
						t.Fatal(err)
					}
					dir := t.TempDir()
					path := filepath.Join(dir, "config.json")
					if err = os.WriteFile(path, raw, 0600); err != nil {
						t.Fatal(err)
					}
					ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
					defer cancel()
					cmd := exec.CommandContext(ctx, binaryPath, coreArgs(id, "check", path, dir)...)
					hideCommand(cmd)
					if out, err := cmd.CombinedOutput(); err != nil {
						t.Fatalf("native validator: %v\n%s", err, out)
					}
					var config object
					_ = json.Unmarshal(raw, &config)
					if id == "sing-box" {
						if obj(config["route"])["final"] != "proxy" {
							t.Fatal("missing proxy default route")
						}
					} else if config["bind-address"] != "127.0.0.1" || config["allow-lan"] != false || config["external-controller"] != nil || config["tun"] != nil {
						t.Fatal("unsafe native listener defaults")
					}
				})
			}
		})
	}
}

// A bounded local VLESS TCP fixture tests actual proxy traffic through the native
// child process, without requiring or claiming access to a remote VPN service.
func nativeVLESSFixture(t *testing.T) (int, *atomic.Int32) {
	t.Helper()
	listener, port, err := reservePort()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	hits := &atomic.Int32{}
	uuid, _ := hex.DecodeString(strings.ReplaceAll(nativeTestUUID, "-", ""))
	go func() {
		for {
			c, err := listener.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				_ = c.SetDeadline(time.Now().Add(15 * time.Second))
				header := make([]byte, 18)
				if _, err := io.ReadFull(c, header); err != nil {
					return
				}
				if header[0] != 0 || string(header[1:17]) != string(uuid) {
					return
				}
				if _, err := io.CopyN(io.Discard, c, int64(header[17])); err != nil {
					return
				}
				addressHeader := make([]byte, 4)
				if _, err := io.ReadFull(c, addressHeader); err != nil || addressHeader[0] != 1 {
					return
				}
				destPort := int(binary.BigEndian.Uint16(addressHeader[1:3]))
				var host string
				switch addressHeader[3] {
				case 1:
					ip := make([]byte, 4)
					if _, err := io.ReadFull(c, ip); err != nil {
						return
					}
					host = net.IP(ip).String()
				case 2:
					size := make([]byte, 1)
					if _, err := io.ReadFull(c, size); err != nil {
						return
					}
					address := make([]byte, int(size[0]))
					if _, err := io.ReadFull(c, address); err != nil {
						return
					}
					host = string(address)
				case 3:
					ip := make([]byte, 16)
					if _, err := io.ReadFull(c, ip); err != nil {
						return
					}
					host = net.IP(ip).String()
				default:
					return
				}
				ip := net.ParseIP(host)
				if ip == nil || !ip.IsLoopback() {
					return
				}
				upstream, err := net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(destPort)), time.Second)
				if err != nil {
					return
				}
				defer upstream.Close()
				hits.Add(1)
				if _, err := c.Write([]byte{0, 0}); err != nil {
					return
				}
				go func() { _, _ = io.Copy(upstream, c); upstream.Close() }()
				_, _ = io.Copy(c, upstream)
			}(c)
		}
	}()
	return port, hits
}

func TestNativeCoreEngineRoundTripAndSelection(t *testing.T) {
	port, hits := nativeVLESSFixture(t)
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "native-core-loopback-roundtrip")
	}))
	defer target.Close()
	for _, id := range []string{"sing-box", "mihomo"} {
		t.Run(id, func(t *testing.T) {
			e := nativeTestEngine(t, id)
			s, err := parseServerURI(fmt.Sprintf("vless://%s@127.0.0.1:%d?security=none#Loopback", nativeTestUUID, port))
			if err != nil {
				t.Fatal(err)
			}
			e.checkURL = target.URL
			initialHits := hits.Load()
			if err = e.Start(s, "local"); err != nil {
				t.Fatalf("start %v; %v", err, e.Status().Logs)
			}
			if err = e.SelectCore("xray"); err == nil {
				t.Fatal("running core switch accepted")
			}
			if _, err = e.Check(context.Background()); err != nil {
				t.Fatalf("health %v; %v", err, e.Status().Logs)
			}
			proxyURL, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", e.Status().HTTPPort))
			tr := &http.Transport{Proxy: http.ProxyURL(proxyURL)}
			defer tr.CloseIdleConnections()
			client := &http.Client{Transport: tr, Timeout: 5 * time.Second}
			resp, err := client.Get(target.URL)
			if err != nil {
				t.Fatal(err)
			}
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			if string(body) != "native-core-loopback-roundtrip" || hits.Load() <= initialHits {
				t.Fatal("native proxy did not carry expected loopback payload")
			}
			if _, err = probeServer(context.Background(), e, s, ProbeSettings{URL: target.URL, TimeoutSeconds: 5, Parallel: 1}); err != nil {
				t.Fatalf("selected-core probe: %v", err)
			}
			if e.Status().Core != id || !e.Status().Checked {
				t.Fatal("wrong core/status")
			}
			invalid := s
			invalid.Outbound = json.RawMessage(strings.ReplaceAll(string(s.Outbound), nativeTestUUID, "11111111-1111-4111-8111-111111111111"))
			if err = e.Start(invalid, "local"); err != nil {
				t.Fatal(err)
			}
			if _, err = e.Check(context.Background()); err == nil || e.Status().Checked {
				t.Fatal("invalid credentials escaped through a direct fallback")
			}
			path, hp := e.configPath, e.Status().HTTPPort
			if err = e.Stop(); err != nil {
				t.Fatal(err)
			}
			if _, err = os.Stat(path); !os.IsNotExist(err) {
				t.Fatal("credentials remain after stop")
			}
			if c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", hp), 100*time.Millisecond); err == nil {
				c.Close()
				t.Fatal("listener remains after stop")
			}
			restored, err := newEngine(e.xrayBinary, e.dir)
			if err != nil {
				t.Fatal(err)
			}
			if restored.Status().Core != id || !restored.Status().Available {
				t.Fatal("selected core not restored")
			}
			a := newTestApp(t)
			owner := create(t, a)
			a.engine = restored
			req := httptest.NewRequest("POST", "/api/connection/core", strings.NewReader(`{"core":"invalid"}`))
			req.RemoteAddr = "127.0.0.1:12345"
			req.Header.Set("Authorization", "Bearer "+owner)
			recorder := httptest.NewRecorder()
			a.handler().ServeHTTP(recorder, req)
			expect(t, recorder, 400)
			req = httptest.NewRequest("POST", "/api/connection/core", strings.NewReader(`{"core":"`+id+`"}`))
			req.RemoteAddr = "127.0.0.1:12345"
			req.Header.Set("Authorization", "Bearer "+owner)
			recorder = httptest.NewRecorder()
			a.handler().ServeHTTP(recorder, req)
			result := expect(t, recorder, 200)
			if result["core"] != id || obj(result["capabilities"])["fullProfiles"] != false || obj(result["capabilities"])["profileSupport"] != "limited" {
				t.Fatal("incorrect native core API response")
			}
		})
	}
}

func TestNativeCoreCapabilitiesMissingAndCorruptSelection(t *testing.T) {
	dir := t.TempDir()
	runtimeDir := filepath.Join(dir, "runtime")
	if err := os.MkdirAll(runtimeDir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(runtimeDir, "core-selection.json"), []byte(`{"core":"unknown"}`), 0600); err != nil {
		t.Fatal(err)
	}
	e, err := newEngine(filepath.Join(dir, "xray"), runtimeDir)
	if err != nil {
		t.Fatal(err)
	}
	status := e.Status()
	if status.Core != "xray" || len(status.Capabilities.Cores) != 3 {
		t.Fatal("invalid default capabilities")
	}
	if status.Capabilities.ProfileSupport != "native" {
		t.Fatal("default core profile support missing")
	}
	for _, c := range status.Capabilities.Cores {
		if c.Installed || c.Available {
			t.Fatal("missing core advertised available")
		}
		if c.ID != "xray" && c.FullProfiles {
			t.Fatal("native full profiles advertised")
		}
		if c.ProfileSupport != coreProfileSupport(c.ID) {
			t.Fatal("incorrect per-core profile support")
		}
	}
	if err = e.SelectCore("sing-box"); err == nil {
		t.Fatal("missing native core selected")
	}
	if e.Status().Core != "xray" {
		t.Fatal("failed selection changed core")
	}
	if err := os.WriteFile(filepath.Join(runtimeDir, "core-selection.json"), []byte(`{"core":"sing-box"}`), 0600); err != nil {
		t.Fatal(err)
	}
	e, err = newEngine(filepath.Join(dir, "xray"), runtimeDir)
	if err != nil {
		t.Fatal(err)
	}
	if status := e.Status(); status.Core != "sing-box" || status.Available || status.Problem != "core_missing" {
		t.Fatal("missing persisted core silently changed or reported available")
	}
}

func TestNativeCoreUnexpectedExitCleanup(t *testing.T) {
	for _, id := range []string{"sing-box", "mihomo"} {
		t.Run(id, func(t *testing.T) {
			e := nativeTestEngine(t, id)
			s, err := parseServerURI("vless://" + nativeTestUUID + "@127.0.0.1:1?security=none#Crash")
			if err != nil {
				t.Fatal(err)
			}
			if err = e.Start(s, "local"); err != nil {
				t.Fatal(err)
			}
			e.op.Lock()
			path, port := e.configPath, e.Status().HTTPPort
			var restored atomic.Int32
			e.restoreProxy = func() error { restored.Add(1); return nil }
			err = e.cmd.Process.Kill()
			e.op.Unlock()
			if err != nil {
				t.Fatal(err)
			}
			deadline := time.Now().Add(5 * time.Second)
			for {
				e.op.Lock()
				cleaned := e.cmd == nil
				e.op.Unlock()
				if cleaned {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("native child crash not cleaned up")
				}
				time.Sleep(20 * time.Millisecond)
			}
			if status := e.Status(); status.State != "error" || status.Error == "" || restored.Load() != 1 {
				t.Fatalf("crash not reported/restored: %+v", status)
			}
			if _, err = os.Stat(path); !os.IsNotExist(err) {
				t.Fatal("crash left credential config")
			}
			if c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 100*time.Millisecond); err == nil {
				c.Close()
				t.Fatal("crash left listener")
			}
		})
	}
}
