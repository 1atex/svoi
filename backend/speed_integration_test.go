package main

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"svoi/internal/speedtest"
	"sync/atomic"
	"testing"
	"time"
)

func TestSpeedThroughRealVLESSCannotFallBackToDirect(t *testing.T) {
	binary := testCore(t)
	listener, port, err := reservePort()
	if err != nil {
		t.Fatal(err)
	}
	listener.Close()
	const id = "90e3da82-374e-46ef-9099-761d39b86b82"
	config := object{"log": object{"loglevel": "none"}, "inbounds": []any{object{"listen": "127.0.0.1", "port": port, "protocol": "vless", "settings": object{"clients": []any{object{"id": id}}, "decryption": "none"}}}, "outbounds": []any{object{"protocol": "freedom", "settings": object{"finalRules": []any{object{"action": "allow", "ip": []string{"127.0.0.1"}}}}}}}
	file := filepath.Join(t.TempDir(), "upstream.json")
	if err = os.WriteFile(file, mustJSON(t, config), 0600); err != nil {
		t.Fatal(err)
	}
	upstream := exec.Command(binary, "run", "-c", file)
	hideCommand(upstream)
	if err = upstream.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { upstream.Process.Kill(); upstream.Wait() }()
	deadline := time.Now().Add(4 * time.Second)
	for {
		conn, e := net.DialTimeout("tcp", "127.0.0.1:"+strconv.Itoa(port), 30*time.Millisecond)
		if e == nil {
			conn.Close()
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("upstream not ready")
		}
		time.Sleep(20 * time.Millisecond)
	}
	node := httptest.NewTLSServer(speedtest.NewHandler(4))
	defer node.Close()
	for _, valid := range []bool{true, false} {
		user := id
		if !valid {
			user = "11111111-1111-4111-8111-111111111111"
		}
		server, e := parseServerURI("vless://" + user + "@127.0.0.1:" + strconv.Itoa(port) + "?security=none#speed")
		if e != nil {
			t.Fatal(e)
		}
		out := object{}
		mustDecode(t, server.Outbound, &out)
		out["tag"] = "vpn"
		server.Profile = mustJSON(t, object{"outbounds": []any{object{"tag": "direct", "protocol": "freedom"}, out}, "routing": object{"rules": []any{object{"type": "field", "network": "tcp,udp", "outboundTag": "direct"}}}})
		a := &App{engine: &Engine{binary: binary, dir: t.TempDir()}}
		ctx, cancel := context.WithTimeout(context.Background(), 7*time.Second)
		transport, cleanup, e := a.speedTransport(ctx, 1, []ServerConfig{server})
		if e != nil {
			cancel()
			t.Fatal(e)
		}
		transport.TLSClientConfig = node.Client().Transport.(*http.Transport).TLSClientConfig.Clone()
		result := measureSpeed(ctx, transport, node.URL+speedtest.Prefix, speedPolicy{Duration: 100 * time.Millisecond, Download: 32 << 10, Upload: 16 << 10}, func(string, int64, float64) {})
		cleanup()
		cancel()
		if valid && result.State != "done" {
			t.Fatalf("valid VLESS failed: %+v", result)
		}
		if !valid && (result.State != "error" || result.Download != nil) {
			t.Fatalf("invalid credentials escaped directly: %+v", result)
		}
		entries, _ := os.ReadDir(a.engine.dir)
		if len(entries) != 0 {
			t.Fatal("temporary core files remain", entries)
		}
	}
}

func mustDecode(t *testing.T, raw []byte, target any) {
	t.Helper()
	if err := json.Unmarshal(raw, target); err != nil {
		t.Fatal(err)
	}
}

func TestSpeedCompletedJobStatus(t *testing.T) {
	a := newTestApp(t)
	token := create(t, a)
	node := httptest.NewServer(speedtest.NewHandler(4))
	defer node.Close()
	a.speedEndpoint = node.URL + speedtest.Prefix
	a.speedDirectDialer = &net.Dialer{}
	policy := speedPolicy{Duration: 100 * time.Millisecond, Download: 32 << 10, Upload: 16 << 10}
	a.speedPolicy = &policy
	call := func(method, path, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		r.RemoteAddr = "127.0.0.1:1234"
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		a.handler().ServeHTTP(w, r)
		return w
	}
	started := expect(t, call("POST", "/api/tools/speed/start", `{"serverIds":[]}`), 200)
	a.speedMu.Lock()
	job := a.speed
	a.speedMu.Unlock()
	select {
	case <-job.done:
	case <-time.After(3 * time.Second):
		t.Fatal("job did not finish")
	}
	status := expect(t, call("GET", "/api/tools/speed/status?id="+started["id"].(string), ""), 200)
	if status["state"] != "done" || len(status["results"].([]any)) != 1 {
		raw, err := json.Marshal(job.results)
		t.Fatalf("status=%v results=%s marshal=%v", status, raw, err)
	}
	row := status["results"].([]any)[0].(map[string]any)
	if row["state"] != "done" || row["downloadBytes"].(float64) != float64(policy.Download) {
		t.Fatal(row)
	}
	expect(t, call("GET", "/api/tools/speed/status?id=unknown", ""), 404)
}

func TestSpeedLiveNode(t *testing.T) {
	if os.Getenv("SVOI_SPEED_LIVE") != "1" {
		t.Skip("opt-in network measurement")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	a := &App{}
	transport, cleanup, err := a.speedTransport(ctx, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer cleanup()
	result := measureSpeed(ctx, transport, "https://svoi.space"+speedtest.Prefix, speedPolicy{Duration: 800 * time.Millisecond, Download: 2 << 20, Upload: 1 << 20}, func(string, int64, float64) {})
	if result.State != "done" || result.Download == nil || result.Upload == nil {
		t.Fatalf("live test failed: %+v", result)
	}
	t.Logf("direct HTTPS response %.1f ms, download %.2f Mbit/s (%d bytes), upload %.2f Mbit/s (%d bytes)", *result.Latency, *result.Download, result.DownloadBytes, *result.Upload, result.UploadBytes)
}

func TestSpeedCancelAPIStopsRequests(t *testing.T) {
	var active atomic.Int32
	node := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		active.Add(1)
		defer active.Add(-1)
		<-r.Context().Done()
	}))
	defer node.Close()
	a := newTestApp(t)
	defer a.closeSpeed()
	token := create(t, a)
	a.speedEndpoint = node.URL + speedtest.Prefix
	a.speedDirectDialer = &net.Dialer{}
	call := func(route string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", "/api/tools/speed/"+route, strings.NewReader(`{"serverIds":[]}`))
		r.RemoteAddr = "127.0.0.1:1234"
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		a.handler().ServeHTTP(w, r)
		return w
	}
	expect(t, call("start"), 200)
	deadline := time.Now().Add(time.Second)
	for active.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if active.Load() == 0 {
		t.Fatal("request never started")
	}
	expect(t, call("start"), 429)
	expect(t, call("cancel"), 200)
	select {
	case <-a.speed.done:
	case <-time.After(time.Second):
		t.Fatal("cancellation did not finish")
	}
	if a.speed.state != "cancelled" {
		t.Fatal(a.speed.state)
	}
	deadline = time.Now().Add(time.Second)
	for active.Load() != 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if active.Load() != 0 {
		t.Fatal("request survived cancellation")
	}
}
