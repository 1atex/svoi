package main

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	binaryencoding "encoding/binary"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func testCore(t *testing.T) string {
	t.Helper()
	path := os.Getenv("SVOI_TEST_CORE")
	if path == "" {
		path = filepath.Join("core", "xray.exe")
	}
	binary, err := filepath.Abs(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = os.Stat(binary); err != nil {
		t.Skip("packaged Xray is unavailable")
	}
	return binary
}

func TestMissingCoreExplainsUnavailableConnection(t *testing.T) {
	dir := t.TempDir()
	engine, err := newEngine(filepath.Join(dir, "core", "xray.exe"), filepath.Join(dir, "runtime"))
	if err != nil {
		t.Fatal(err)
	}
	status := engine.Status()
	if status.Available || status.Problem != "core_missing" || !strings.Contains(status.Error, "Windows-архив") {
		t.Fatalf("missing actionable diagnostic: %+v", status)
	}
}
func TestParserTransportsWithRealXray(t *testing.T) {
	binary := testCore(t)
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pub := base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes())
	const id = "90e3da82-374e-46ef-9099-761d39b86b82"
	vmess, _ := json.Marshal(object{"v": "2", "ps": "VMess test", "add": "example.com", "port": "443", "id": id, "aid": "0", "net": "ws", "path": "/socket", "host": "example.com", "tls": "tls", "sni": "example.com"})
	cases := []string{
		"vless://" + id + "@example.com:443?security=reality&sni=example.com&fp=chrome&pbk=" + pub + "&sid=abcd&flow=xtls-rprx-vision#Reality",
		"vless://" + id + "@example.com:443?security=tls&sni=example.com&type=ws&path=%2Fproxy&host=example.com#WS",
		"vless://" + id + "@example.com:443?security=tls&type=grpc&serviceName=service#GRPC",
		"vless://" + id + "@example.com:443?security=tls&type=xhttp&path=%2Fx&mode=auto#XHTTP",
		"vmess://" + base64.StdEncoding.EncodeToString(vmess),
		"trojan://test-password@example.com:443?sni=example.com#Trojan",
		"ss://" + base64.RawURLEncoding.EncodeToString([]byte("aes-128-gcm:test-password")) + "@example.com:8388#SS",
	}
	for _, uri := range cases {
		server, err := parseServerURI(uri)
		if err != nil {
			t.Fatal(err)
		}
		t.Run(server.Name, func(t *testing.T) {
			b, err := buildXrayConfig(server, 10808, 10809, "local")
			if err != nil {
				t.Fatal(err)
			}
			file := filepath.Join(t.TempDir(), "config.json")
			if err = os.WriteFile(file, b, 0600); err != nil {
				t.Fatal(err)
			}
			cmd := exec.Command(binary, "run", "-test", "-c", file)
			hideCommand(cmd)
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("Xray rejected %s: %s", server.Name, out)
			}
		})
	}
}
func TestXrayVLESSRoundTrip(t *testing.T) {
	binary := testCore(t)
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Svoi-Test", "through-xray")
		_, _ = io.WriteString(w, "svoi-xray-roundtrip")
	}))
	defer target.Close()
	l, port, err := reservePort()
	if err != nil {
		t.Fatal(err)
	}
	l.Close()
	const id = "90e3da82-374e-46ef-9099-761d39b86b82"
	serverConfig := object{"log": object{"loglevel": "debug"}, "inbounds": []any{object{"listen": "127.0.0.1", "port": port, "protocol": "vless", "settings": object{"clients": []any{object{"id": id}}, "decryption": "none"}}}, "outbounds": []any{object{"protocol": "freedom", "settings": object{"finalRules": []any{object{"action": "allow", "ip": []string{"127.0.0.1"}}}}}}}
	file := filepath.Join(t.TempDir(), "server.json")
	b, _ := json.Marshal(serverConfig)
	if err = os.WriteFile(file, b, 0600); err != nil {
		t.Fatal(err)
	}
	upstream := exec.Command(binary, "run", "-c", file)
	var upstreamLogs bytes.Buffer
	upstream.Stdout = &upstreamLogs
	upstream.Stderr = &upstreamLogs
	hideCommand(upstream)
	if err = upstream.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		upstream.Process.Kill()
		upstream.Wait()
		if t.Failed() {
			t.Log(upstreamLogs.String())
		}
	}()
	deadline := time.Now().Add(5 * time.Second)
	for {
		c, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), 100*time.Millisecond)
		if err == nil {
			c.Close()
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("test VLESS server did not start")
		}
		time.Sleep(30 * time.Millisecond)
	}
	server, err := parseServerURI("vless://" + id + "@127.0.0.1:" + strconv.Itoa(port) + "?security=none#Roundtrip")
	if err != nil {
		t.Fatal(err)
	}
	engine, err := newEngine(binary, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer engine.Stop()
	engine.checkURL = target.URL
	if err = engine.Start(server, "local"); err != nil {
		t.Fatalf("start: %v; logs: %v", err, engine.Status().Logs)
	}
	if _, err = engine.Check(context.Background()); err != nil {
		t.Fatalf("roundtrip: %v; logs: %v", err, engine.Status().Logs)
	}
	status := engine.Status()
	if !status.Checked || status.State != "running" {
		t.Fatal("connection not verified")
	}
	// SOCKS5 must also work, not merely the HTTP inbound.
	conn, err := net.Dial("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(status.SocksPort)))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	conn.Write([]byte{5, 1, 0})
	reply := make([]byte, 2)
	if _, err = io.ReadFull(conn, reply); err != nil || reply[0] != 5 || reply[1] != 0 {
		t.Fatal("SOCKS5 negotiation failed")
	}
	targetPort := target.Listener.Addr().(*net.TCPAddr).Port
	request := []byte{5, 1, 0, 1, 127, 0, 0, 1, 0, 0}
	binaryencoding.BigEndian.PutUint16(request[8:], uint16(targetPort))
	conn.Write(request)
	response := make([]byte, 10)
	if _, err = io.ReadFull(conn, response); err != nil || response[1] != 0 {
		t.Fatal("SOCKS5 connection failed")
	}
	io.WriteString(conn, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
	body, err := io.ReadAll(conn)
	if err != nil || !bytes.Contains(body, []byte("svoi-xray-roundtrip")) {
		t.Fatalf("SOCKS5 did not deliver target response: %v", err)
	}
	if err = engine.Stop(); err != nil {
		t.Fatal(err)
	}
	if engine.Status().State != "stopped" {
		t.Fatal("engine did not stop")
	}
	if c, err := net.DialTimeout("tcp", "127.0.0.1:"+strconv.Itoa(status.HTTPPort), 200*time.Millisecond); err == nil {
		c.Close()
		t.Fatal("HTTP port remains open")
	}
	// Default outbound is blackhole: this succeeds only if original inbound
	// tags, entry balancer, loopback tag and exit balancer all survive import.
	profile, err := serverFromProfile(loopbackProfile(t, server), 1)
	if err != nil {
		t.Fatal(err)
	}
	if err = engine.Start(profile, "local"); err != nil {
		t.Fatalf("full profile start: %v; logs: %v", err, engine.Status().Logs)
	}
	if _, err = engine.Check(context.Background()); err != nil {
		t.Fatalf("loopback/balancer roundtrip: %v; logs: %v", err, engine.Status().Logs)
	}
}

func TestTunHealthCheckUsesSystemRoute(t *testing.T) {
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	defer target.Close()
	// An unreachable HTTP proxy must not affect the TUN diagnostic path.
	e := &Engine{status: EngineStatus{State: "running", Mode: "tun", HTTPPort: 0}, checkURL: target.URL}
	if _, err := e.Check(context.Background()); err != nil {
		t.Fatalf("TUN check used the HTTP proxy: %v", err)
	}
	if !e.Status().Checked {
		t.Fatal("successful check not recorded")
	}
}
func TestXrayUnexpectedExitCleanup(t *testing.T) {
	e, err := newEngine(testCore(t), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer e.Stop()
	server, err := parseServerURI("vless://90e3da82-374e-46ef-9099-761d39b86b82@127.0.0.1:1?security=none#Crash-test")
	if err != nil {
		t.Fatal(err)
	}
	if err = e.Start(server, "local"); err != nil {
		t.Fatal(err)
	}
	e.op.Lock()
	path := e.configPath
	port := e.Status().HTTPPort
	restored := 0
	// Exercise lifecycle recovery without changing this computer's registry.
	e.restoreProxy = func() error { restored++; return nil }
	err = e.cmd.Process.Kill()
	e.op.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		e.op.Lock()
		clean := e.cmd == nil && restored == 1
		e.op.Unlock()
		if clean {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("crashed core was not cleaned up")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if s := e.Status(); s.State != "error" || s.Error == "" {
		t.Fatalf("crash not reported: %+v", s)
	}
	if _, err = os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("temporary credential config remains")
	}
	if c, err := net.DialTimeout("tcp", "127.0.0.1:"+strconv.Itoa(port), 200*time.Millisecond); err == nil {
		c.Close()
		t.Fatal("crashed core left port open")
	}
}
func TestImportedServersAndRedaction(t *testing.T) {
	a := newTestApp(t)
	owner := create(t, a)
	raw := "vless://private-credential@example.com:443?security=tls#Primary\nhy2://unsupported@example.com:443#Unsupported\nvless://private-credential@example.com:443?security=tls#Duplicate"
	v := expect(t, call(a, "POST", "/api/subscription/import", owner, map[string]string{"content": raw}), 200)
	servers := v["servers"].([]any)
	if len(servers) != 1 {
		t.Fatal("deduplication failed")
	}
	if strings.Contains(string(mustJSON(t, v)), "private-credential") {
		t.Fatal("public summary exposes credentials")
	}
	if len(v["lastRefresh"].(map[string]any)["warnings"].([]any)) != 1 {
		t.Fatal("unsupported lines not reported")
	}
	restored, err := openApp(a.path)
	if err != nil {
		t.Fatal(err)
	}
	if len(restored.state.Groups[0].Servers) != 1 {
		t.Fatal("servers not persisted")
	}
	expect(t, call(a, "POST", "/api/subscription/import", owner, map[string]string{"content": "invalid"}), 422)
	if len(a.state.Groups[0].Servers) != 1 {
		t.Fatal("invalid import erased previous servers")
	}
	expect(t, call(a, "POST", "/api/connection/start", owner, map[string]string{"serverId": "x", "mode": "local"}), 403)
}
