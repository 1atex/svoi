package main

import (
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func providerDefaultNode(t *testing.T, port int, publicKey string) ServerConfig {
	t.Helper()
	server, err := parseServerURI(fmt.Sprintf("vless://%s@127.0.0.1:%d?security=reality&sni=example.com&fp=qq&pbk=%s&sid=abcd&spx=%%2F", nativeTestUUID, port, publicKey))
	if err != nil {
		t.Fatal(err)
	}
	var outbound object
	if err = json.Unmarshal(server.Outbound, &outbound); err != nil {
		t.Fatal(err)
	}
	outbound["mux"] = object{"enabled": false, "concurrency": -1, "xudpConcurrency": 8, "xudpProxyUDP443": ""}
	obj(outbound["streamSettings"])["tcpSettings"] = object{}
	server.Outbound, err = json.Marshal(outbound)
	if err != nil {
		t.Fatal(err)
	}
	return server
}

func TestNativeCoreProviderDefaultsValidation(t *testing.T) {
	server := providerDefaultNode(t, 443, "FbzRLPlQIpk7z1rfW4mG0mFBQ9LB9nc8LmGvzKDSRCE")
	original := string(server.Outbound)
	for _, id := range []string{"sing-box", "mihomo"} {
		t.Run(id, func(t *testing.T) {
			binaryPath := testNativeCore(t, id)
			raw, err := buildCoreConfig(id, server, 21081, 21082, "local")
			if err != nil {
				t.Fatal(err)
			}
			if string(server.Outbound) != original {
				t.Fatal("provider outbound mutated during translation")
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
				t.Fatalf("native provider-default config rejected: %v\n%s", err, out)
			}
			var config object
			_ = json.Unmarshal(raw, &config)
			if id == "sing-box" {
				proxy := firstObject(config["outbounds"])
				tls := obj(proxy["tls"])
				if obj(tls["utls"])["fingerprint"] != "qq" || obj(tls["reality"])["public_key"] == nil || tls["insecure"] == true || proxy["multiplex"] != nil {
					t.Fatal("security settings weakened or mux enabled")
				}
			} else {
				proxy := firstObject(config["proxies"])
				if proxy["client-fingerprint"] != "qq" || obj(proxy["reality-opts"])["public-key"] == nil || proxy["skip-cert-verify"] == true || proxy["smux"] != nil {
					t.Fatal("security settings weakened or mux enabled")
				}
			}
		})
	}
}

func TestNativeCoreProviderDefaultsRemainBounded(t *testing.T) {
	for _, id := range []string{"sing-box", "mihomo"} {
		for _, change := range []string{"enabled-mux", "unknown-mux-option", "missing-mux-enabled", "wrong-mux-type", "wrong-concurrency-type", "custom-spider-path"} {
			t.Run(id+"/"+change, func(t *testing.T) {
				server := providerDefaultNode(t, 443, "FbzRLPlQIpk7z1rfW4mG0mFBQ9LB9nc8LmGvzKDSRCE")
				var outbound object
				_ = json.Unmarshal(server.Outbound, &outbound)
				switch change {
				case "enabled-mux":
					obj(outbound["mux"])["enabled"] = true
				case "unknown-mux-option":
					obj(outbound["mux"])["futureFeature"] = true
				case "missing-mux-enabled":
					delete(obj(outbound["mux"]), "enabled")
				case "wrong-mux-type":
					outbound["mux"] = false
				case "wrong-concurrency-type":
					obj(outbound["mux"])["concurrency"] = "-1"
				case "custom-spider-path":
					obj(obj(outbound["streamSettings"])["realitySettings"])["spiderX"] = "/custom/path"
				}
				server.Outbound, _ = json.Marshal(outbound)
				if _, err := buildCoreConfig(id, server, 21081, 21082, "local"); err == nil {
					t.Fatal("unsupported customization silently accepted")
				}
			})
		}
	}
}

// All three processes and both HTTP fixtures remain on loopback. This covers
// provider-shaped Reality traffic, rather than just native config acceptance.
// This fixture uses a compatible official sing-box server. Newer Xray server
// versions mandate ML-KEM key shares unsupported by some native fingerprints;
// passing this test does not imply compatibility with every Reality server.
func TestNativeCoreProviderRealityLoopback(t *testing.T) {
	serverBinary := testNativeCore(t, "sing-box")
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	publicKey := base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes())
	privateKey := base64.RawURLEncoding.EncodeToString(key.Bytes())
	camouflage := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	camouflage.EnableHTTP2 = true
	camouflage.Config.ErrorLog = log.New(io.Discard, "", 0)
	camouflage.TLS = &tls.Config{MinVersion: tls.VersionTLS13}
	camouflage.StartTLS()
	defer camouflage.Close()
	var hits atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		_, _ = io.WriteString(w, "provider-reality-loopback")
	}))
	defer target.Close()
	listener, port, err := reservePort()
	if err != nil {
		t.Fatal(err)
	}
	listener.Close()
	camouflageHost, camouflagePortText, err := net.SplitHostPort(strings.TrimPrefix(camouflage.URL, "https://"))
	if err != nil {
		t.Fatal(err)
	}
	camouflagePort, _ := strconv.Atoi(camouflagePortText)
	config := object{
		"log": object{"level": "warn"},
		"inbounds": []any{object{
			"type": "vless", "listen": "127.0.0.1", "listen_port": port,
			"users": []any{object{"uuid": nativeTestUUID}},
			"tls": object{"enabled": true, "server_name": "example.com", "reality": object{"enabled": true,
				"handshake":   object{"server": camouflageHost, "server_port": camouflagePort},
				"private_key": privateKey, "short_id": []string{"abcd"},
			}},
		}},
		"outbounds": []any{object{"type": "direct"}},
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "server.json")
	raw, _ := json.Marshal(config)
	if err = os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	upstream := exec.Command(serverBinary, "run", "-c", path)
	upstreamLog := &Engine{coreStarted: true, redactions: []string{nativeTestUUID, privateKey}}
	upstream.Stdout, upstream.Stderr = upstreamLog, upstreamLog
	hideCommand(upstream)
	if err = upstream.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = upstream.Process.Kill(); _ = upstream.Wait() }()
	deadline := time.Now().Add(5 * time.Second)
	for {
		c, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), 100*time.Millisecond)
		if err == nil {
			c.Close()
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("loopback Reality server did not start")
		}
		time.Sleep(20 * time.Millisecond)
	}
	for _, id := range []string{"sing-box", "mihomo"} {
		t.Run(id, func(t *testing.T) {
			engine := nativeTestEngine(t, id)
			engine.checkURL = target.URL
			engine.checkTimeout = 5 * time.Second
			server := providerDefaultNode(t, port, publicKey)
			before := hits.Load()
			if err := engine.Start(server, "local"); err != nil {
				t.Fatalf("native provider-shaped start: %v", err)
			}
			if _, err := engine.Check(context.Background()); err != nil {
				t.Logf("Reality fixture logs: %v", upstreamLog.Status().Logs)
				t.Fatalf("native Reality loopback GET failed: %v; logs: %v", err, engine.Status().Logs)
			}
			if hits.Load() <= before {
				t.Fatal("HTTP payload did not cross Reality server")
			}
		})
	}
}
