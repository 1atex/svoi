package main

import (
	"context"
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
	"reflect"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func nativeHysteriaTestOutbound(t *testing.T, uri string) object {
	t.Helper()
	server, err := parseServerURI(uri)
	if err != nil {
		t.Fatal(err)
	}
	var out object
	if err = json.Unmarshal(server.Outbound, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func TestNativeHysteriaConfigChecks(t *testing.T) {
	cert, _ := hysteriaTestCertificate(t)
	for _, id := range []string{"sing-box", "mihomo"} {
		t.Run(id, func(t *testing.T) {
			binary := testNativeCore(t, id)
			verification := "verified-ca"
			if id == "mihomo" {
				verification = "explicit-insecure"
			}
			for _, shape := range []string{"plain", "userpass", "salamander", "hopping", "salamander-hopping", verification} {
				t.Run(shape, func(t *testing.T) {
					uri := "hy2://user:p%40ss@example.org:443?sni=tls.example.org&alpn=h3"
					if shape == "plain" {
						uri = "hy2://example.org"
					}
					if strings.Contains(shape, "salamander") {
						uri += "&obfs=salamander&obfs-password=obfs-secret"
					}
					if strings.Contains(shape, "hopping") {
						uri += "&mport=443,8443-8445&hop-interval=5"
					}
					out := nativeHysteriaTestOutbound(t, uri)
					if shape == verification {
						tls := obj(obj(out["streamSettings"])["tlsSettings"])
						if id == "sing-box" {
							tls["certificates"] = []any{object{"usage": "verify", "certificate": strings.Split(cert, "\n")}}
							tls["disableSystemRoot"] = true
						} else {
							tls["allowInsecure"] = true
						}
					}
					before, _ := json.Marshal(out)
					data, err := buildCoreConfig(id, ServerConfig{Outbound: before}, 21081, 21082, "local")
					if id == "mihomo" && strings.Contains(shape, "hopping") {
						if err == nil {
							t.Fatal("Mihomo silently dropped local port rotation")
						}
						return
					}
					if err != nil {
						t.Fatal(err)
					}
					after, _ := json.Marshal(out)
					if string(before) != string(after) {
						t.Fatal("source outbound changed")
					}
					var config object
					_ = json.Unmarshal(data, &config)
					var proxy object
					if id == "sing-box" {
						proxy = firstObject(config["outbounds"])
						if obj(config["route"])["final"] != "proxy" {
							t.Fatal("missing forced proxy route")
						}
					} else {
						proxy = firstObject(config["proxies"])
						if config["bind-address"] != "127.0.0.1" || config["external-controller"] != nil || config["tun"] != nil || config["allow-lan"] != false {
							t.Fatal("unsafe native defaults")
						}
					}
					wantPassword := "user:p@ss"
					if shape == "plain" {
						wantPassword = ""
					}
					if proxy["password"] != wantPassword {
						t.Fatal("authentication string changed")
					}
					if strings.Contains(shape, "hopping") {
						if id == "sing-box" {
							if !reflect.DeepEqual(proxy["server_ports"], []any{"443:443", "8443:8445"}) || proxy["hop_interval"] != "5s" || proxy["server_port"] != nil {
								t.Fatal("incorrect sing-box hopping")
							}
						} else if proxy["ports"] != "443,8443-8445" || proxy["hop-interval"] != "5" || proxy["port"] != nil {
							t.Fatal("incorrect Mihomo hopping")
						}
					}
					dir := t.TempDir()
					path := filepath.Join(dir, "config.json")
					if err = os.WriteFile(path, data, 0600); err != nil {
						t.Fatal(err)
					}
					ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
					defer cancel()
					cmd := exec.CommandContext(ctx, binary, coreArgs(id, "check", path, dir)...)
					hideCommand(cmd)
					if result, err := cmd.CombinedOutput(); err != nil {
						t.Fatalf("native check rejected Hysteria2: %v\n%s", err, result)
					}
				})
			}
		})
	}
}

func TestNativeHysteriaRejectsLossyOptions(t *testing.T) {
	edits := map[string]func(object){
		"v1":              func(o object) { obj(o["settings"])["version"] = 1 },
		"unknown-setting": func(o object) { obj(o["settings"])["congestion"] = "custom" },
		"bad-auth-type":   func(o object) { obj(obj(o["streamSettings"])["hysteriaSettings"])["auth"] = false },
		"bad-stream":      func(o object) { o["streamSettings"] = false },
		"bad-tls":         func(o object) { obj(o["streamSettings"])["security"] = "none" },
		"bad-tls-type":    func(o object) { obj(o["streamSettings"])["tlsSettings"] = false },
		"insecure-type":   func(o object) { obj(obj(o["streamSettings"])["tlsSettings"])["allowInsecure"] = "true" },
		"ech":             func(o object) { obj(obj(o["streamSettings"])["tlsSettings"])["echConfigList"] = "AA==" },
		"pin-chain": func(o object) {
			obj(obj(o["streamSettings"])["tlsSettings"])["pinnedPeerCertificateChainSha256"] = []any{"AA=="}
		},
		"pin-leaf":     func(o object) { obj(obj(o["streamSettings"])["tlsSettings"])["pinnedPeerCertSha256"] = []any{"AA=="} },
		"pin-hysteria": func(o object) { obj(obj(o["streamSettings"])["tlsSettings"])["pinSHA256"] = "0011" },
		"fingerprint":  func(o object) { obj(obj(o["streamSettings"])["tlsSettings"])["fingerprint"] = "chrome" },
		"sockopt":      func(o object) { obj(o["streamSettings"])["sockopt"] = object{"dialerProxy": "chain"} },
		"unknown-mask": func(o object) {
			obj(o["streamSettings"])["finalmask"] = object{"udp": []any{object{"type": "unknown"}}}
		},
		"unknown-finalmask": func(o object) { obj(o["streamSettings"])["finalmask"] = object{"tcp": []any{}} },
		"active-mux":        func(o object) { o["mux"] = object{"enabled": true} },
		"short-obfs-password": func(o object) {
			obj(firstObject(obj(obj(o["streamSettings"])["finalmask"])["udp"])["settings"])["password"] = "a"
		},
		"custom-hop-mode": func(o object) {
			obj(obj(o["streamSettings"])["finalmask"])["udp"] = []any{object{"type": "udphop", "settings": object{"mode": "intervalRemote", "interval": 5, "remotePorts": "443,8443"}}}
		},
		"hop-interval-clamping": func(o object) {
			obj(obj(o["streamSettings"])["finalmask"])["udp"] = []any{object{"type": "udphop", "settings": object{"mode": "intervalLocal,intervalRemote", "interval": 1, "remotePorts": "443,8443"}}}
		},
	}
	for _, id := range []string{"sing-box", "mihomo"} {
		for name, edit := range edits {
			t.Run(id+"/"+name, func(t *testing.T) {
				out := nativeHysteriaTestOutbound(t, "hy2://pass@example.org?obfs=salamander&obfs-password=obfs-secret")
				edit(out)
				if _, err := nativeHysteriaConfig(id, out, 21081, 21082); err == nil {
					t.Fatal("unsupported Hysteria2 option silently dropped")
				}
			})
		}
	}
}

func TestNativeHysteriaTrustBoundaries(t *testing.T) {
	certificate, _ := hysteriaTestCertificate(t)
	for _, id := range []string{"sing-box", "mihomo"} {
		out := nativeHysteriaTestOutbound(t, "hy2://test-password@example.org")
		tls := obj(obj(out["streamSettings"])["tlsSettings"])
		tls["certificates"] = []any{object{"usage": "verify", "certificate": strings.Split(certificate, "\n")}}
		if _, err := nativeHysteriaConfig(id, out, 21081, 21082); err == nil {
			t.Fatal("custom root semantics were silently changed")
		}
		if id == "mihomo" {
			tls["disableSystemRoot"] = true
			if _, err := nativeHysteriaConfig(id, out, 21081, 21082); err == nil {
				t.Fatal("Mihomo custom root bug incorrectly advertised supported")
			}
		}
	}
}

// Front ports forward to one real Hysteria2 UDP server using one upstream
// socket. This models server-side port forwarding entirely on loopback, and
// makes an actual client port hop observable without changing OS networking.
func hysteriaHopForwarder(t *testing.T, serverPort int) (string, func() int) {
	t.Helper()
	backend, err := net.Dial("udp4", fmt.Sprintf("127.0.0.1:%d", serverPort))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { backend.Close() })
	var mu sync.Mutex
	var active net.PacketConn
	var peer net.Addr
	seen := map[string]bool{}
	ports := []string{}
	for range 2 {
		listener, err := net.ListenPacket("udp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { listener.Close() })
		ports = append(ports, strconv.Itoa(listener.LocalAddr().(*net.UDPAddr).Port))
		go func() {
			buf := make([]byte, 65535)
			for {
				n, p, err := listener.ReadFrom(buf)
				if err != nil {
					return
				}
				mu.Lock()
				active, peer = listener, p
				seen[p.String()+"@"+listener.LocalAddr().String()] = true
				mu.Unlock()
				if _, err = backend.Write(buf[:n]); err != nil {
					return
				}
			}
		}()
	}
	go func() {
		buf := make([]byte, 65535)
		for {
			n, err := backend.Read(buf)
			if err != nil {
				return
			}
			mu.Lock()
			l, p := active, peer
			mu.Unlock()
			if l != nil {
				_, _ = l.WriteTo(buf[:n], p)
			}
		}
	}()
	return strings.Join(ports, ","), func() int { mu.Lock(); defer mu.Unlock(); return len(seen) }
}

func TestNativeHysteriaHTTPRoundTrip(t *testing.T) {
	xray := testCore(t)
	cert, key := hysteriaTestCertificate(t)
	const password = "test-user:local-hysteria-secret"
	for _, obfs := range []bool{false, true} {
		t.Run(fmt.Sprint(obfs), func(t *testing.T) {
			socket, err := net.ListenPacket("udp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			port := socket.LocalAddr().(*net.UDPAddr).Port
			socket.Close()
			stream := object{"network": "hysteria", "security": "tls", "hysteriaSettings": object{"version": 2}, "tlsSettings": object{"alpn": []string{"h3"}, "certificates": []any{object{"certificate": strings.Split(cert, "\n"), "key": strings.Split(key, "\n")}}}}
			if obfs {
				stream["finalmask"] = object{"udp": []any{object{"type": "salamander", "settings": object{"password": "obfs-secret"}}}}
			}
			config := object{"log": object{"loglevel": "warning"}, "inbounds": []any{object{"listen": "127.0.0.1", "port": port, "protocol": "hysteria", "settings": object{"version": 2, "users": []any{object{"auth": password}}}, "streamSettings": stream}}, "outbounds": []any{object{"protocol": "freedom", "settings": object{"finalRules": []any{object{"action": "allow", "ip": []string{"127.0.0.1"}}}}}}}
			dir := t.TempDir()
			serverPath := filepath.Join(dir, "server.json")
			raw, _ := json.Marshal(config)
			if err = os.WriteFile(serverPath, raw, 0600); err != nil {
				t.Fatal(err)
			}
			serverLog := &Engine{redactions: []string{password, "obfs-secret"}}
			cmd := exec.Command(xray, "run", "-c", serverPath)
			hideCommand(cmd)
			cmd.Stdout, cmd.Stderr = serverLog, serverLog
			if err = cmd.Start(); err != nil {
				t.Fatal(err)
			}
			defer func() { cmd.Process.Kill(); cmd.Wait() }()
			deadline := time.Now().Add(5 * time.Second)
			for {
				serverLog.mu.Lock()
				ready := serverLog.coreStarted
				serverLog.mu.Unlock()
				if ready {
					break
				}
				if time.Now().After(deadline) {
					t.Fatalf("local Hysteria2 fixture did not start: %v", serverLog.Status().Logs)
				}
				time.Sleep(20 * time.Millisecond)
			}
			for _, id := range []string{"sing-box", "mihomo"} {
				t.Run(id, func(t *testing.T) {
					binary := testNativeCore(t, id)
					var hits atomic.Int32
					target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
						hits.Add(1)
						_, _ = io.WriteString(w, "native-hysteria2-loopback-payload")
					}))
					defer target.Close()
					ports, seenHops := hysteriaHopForwarder(t, port)
					suffix := "?sni=localhost&alpn=h3"
					if id == "sing-box" {
						suffix += "&mport=" + ports + "&hop-interval=5"
					}
					if obfs {
						suffix += "&obfs=salamander&obfs-password=obfs-secret"
					}
					out := nativeHysteriaTestOutbound(t, "hy2://test-user:local-hysteria-secret@127.0.0.1:"+strconv.Itoa(port)+suffix)
					tls := obj(obj(out["streamSettings"])["tlsSettings"])
					if id == "sing-box" {
						tls["certificates"] = []any{object{"usage": "verify", "certificate": strings.Split(cert, "\n")}}
						tls["disableSystemRoot"] = true
					} else {
						// This is explicitly a protocol/obfs/hopping fixture. The
						// native version's custom-CA bug is rejected in the adapter;
						// verification defaults are tested separately below.
						tls["allowInsecure"] = true
					}
					socks, udp, sp, err := reserveSocksPort()
					if err != nil {
						t.Fatal(err)
					}
					defer socks.Close()
					defer udp.Close()
					httpListener, hp, err := reservePort()
					if err != nil {
						t.Fatal(err)
					}
					defer httpListener.Close()
					data, err := nativeHysteriaConfig(id, out, sp, hp)
					if err != nil {
						t.Fatal(err)
					}
					runtimeDir := t.TempDir()
					path := filepath.Join(runtimeDir, "config.json")
					if err = os.WriteFile(path, data, 0600); err != nil {
						t.Fatal(err)
					}
					clientLog := &Engine{coreStarted: true, redactions: []string{password, "obfs-secret"}}
					client := exec.Command(binary, coreArgs(id, "run", path, runtimeDir)...)
					hideCommand(client)
					client.Stdout, client.Stderr = clientLog, clientLog
					socks.Close()
					udp.Close()
					httpListener.Close()
					if err = client.Start(); err != nil {
						t.Fatal(err)
					}
					defer func() {
						client.Process.Kill()
						client.Wait()
						if t.Failed() {
							t.Log(clientLog.Status().Logs)
							t.Log(serverLog.Status().Logs)
						}
					}()
					proxyURL, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", hp))
					tr := &http.Transport{Proxy: http.ProxyURL(proxyURL), DisableKeepAlives: true}
					defer tr.CloseIdleConnections()
					hc := &http.Client{Transport: tr, Timeout: 3 * time.Second}
					deadline = time.Now().Add(5 * time.Second)
					for {
						c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", hp), 100*time.Millisecond)
						if err == nil {
							c.Close()
							break
						}
						if time.Now().After(deadline) {
							t.Fatal("native Hysteria client listener did not start")
						}
						time.Sleep(20 * time.Millisecond)
					}
					// Mihomo binds HTTP before its tunnel transitions to Running.
					// A TCP accept alone can therefore precede a synthetic HTTP 502.
					// Require the exact local sentinel within the same startup budget;
					// the traffic and negative checks below never retry failures.
					startupContext, cancelStartup := context.WithDeadline(context.Background(), deadline)
					defer cancelStartup()
					var startupStatus string
					var startupBody []byte
					var startupError error
					for {
						request, err := http.NewRequestWithContext(startupContext, http.MethodGet, target.URL, nil)
						if err != nil {
							t.Fatal(err)
						}
						response, err := hc.Do(request)
						startupError = err
						if err == nil {
							startupStatus = response.Status
							startupBody, startupError = io.ReadAll(io.LimitReader(response.Body, 1024))
							response.Body.Close()
							if startupError == nil && response.StatusCode == http.StatusOK && string(startupBody) == "native-hysteria2-loopback-payload" {
								break
							}
						}
						if startupContext.Err() != nil {
							t.Fatalf("native Hysteria startup sentinel failed core=%s socks=%d http=%d serverUDP=%d status=%s body=%q error=%v clientLogs=%v", id, sp, hp, port, startupStatus, startupBody, startupError, clientLog.Status().Logs)
						}
						poll := time.NewTimer(20 * time.Millisecond)
						select {
						case <-startupContext.Done():
							if !poll.Stop() {
								<-poll.C
							}
						case <-poll.C:
						}
					}
					cancelStartup()
					start := time.Now()
					normalRequests := 0
					for {
						response, err := hc.Get(target.URL)
						if err != nil {
							t.Fatalf("Hysteria2 HTTP failed core=%s socks=%d http=%d serverUDP=%d pid=%d target=%s elapsed=%s: %v", id, sp, hp, port, client.Process.Pid, target.URL, time.Since(start), err)
						}
						body, _ := io.ReadAll(response.Body)
						response.Body.Close()
						if response.StatusCode != 200 || string(body) != "native-hysteria2-loopback-payload" {
							t.Fatalf("Hysteria2 payload mismatch core=%s socks=%d http=%d serverUDP=%d pid=%d target=%s elapsed=%s status=%s body=%q hits=%d clientLogs=%v serverLogs=%v", id, sp, hp, port, client.Process.Pid, target.URL, time.Since(start), response.Status, string(body), hits.Load(), clientLog.Status().Logs, serverLog.Status().Logs)
						}
						normalRequests++
						if id == "mihomo" && normalRequests >= 2 {
							break
						}
						if time.Since(start) > 5*time.Second && seenHops() > 1 {
							break
						}
						if time.Since(start) > 13*time.Second {
							t.Fatal("actual port hopping did not occur")
						}
						time.Sleep(150 * time.Millisecond)
					}
					if normalRequests < 2 {
						t.Fatal("traffic did not survive hopping")
					}
					testHysteriaUDP(t, sp)
					_ = client.Process.Kill()
					_ = client.Wait()
					for _, failure := range []string{"auth", "verification"} {
						var invalid object
						original, _ := json.Marshal(out)
						_ = json.Unmarshal(original, &invalid)
						if failure == "auth" {
							obj(obj(invalid["streamSettings"])["hysteriaSettings"])["auth"] = "wrong-test-auth"
						} else {
							invalidTLS := obj(obj(invalid["streamSettings"])["tlsSettings"])
							if id == "sing-box" {
								invalidTLS["serverName"] = "wrong.example.invalid"
							} else {
								delete(invalidTLS, "allowInsecure")
							}
						}
						badConfig, err := nativeHysteriaConfig(id, invalid, sp, hp)
						if err != nil {
							t.Fatal(err)
						}
						if err = os.WriteFile(path, badConfig, 0600); err != nil {
							t.Fatal(err)
						}
						badClient := exec.Command(binary, coreArgs(id, "run", path, runtimeDir)...)
						hideCommand(badClient)
						badClient.Stdout, badClient.Stderr = clientLog, clientLog
						if err = badClient.Start(); err != nil {
							t.Fatal(err)
						}
						func() {
							defer func() { _ = badClient.Process.Kill(); _ = badClient.Wait() }()
							readyDeadline := time.Now().Add(5 * time.Second)
							for {
								c, e := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", hp), 100*time.Millisecond)
								if e == nil {
									c.Close()
									break
								}
								if time.Now().After(readyDeadline) {
									t.Fatal("negative fixture client did not start")
								}
								time.Sleep(20 * time.Millisecond)
							}
							before := hits.Load()
							response, requestErr := hc.Get(target.URL)
							if requestErr == nil {
								io.Copy(io.Discard, response.Body)
								response.Body.Close()
								if response.StatusCode == 200 {
									t.Fatalf("invalid %s bypassed Hysteria2 validation", failure)
								}
							}
							if hits.Load() != before {
								t.Fatalf("invalid %s escaped through direct route", failure)
							}
						}()
					}
				})
			}
		})
	}
}
