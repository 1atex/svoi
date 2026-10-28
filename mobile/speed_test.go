package mobile

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/xtls/xray-core/core"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"svoi/internal/speedtest"
	"sync/atomic"
	"testing"
	"time"
)

func speedCall(t *testing.T, s *Session, method, path, token string, body any, status int) map[string]any {
	t.Helper()
	raw, _ := json.Marshal(body)
	var response struct {
		Status int
		Body   map[string]any
	}
	if err := json.Unmarshal([]byte(s.Request(method, path, token, string(raw))), &response); err != nil {
		t.Fatal(err)
	}
	if response.Status != status {
		t.Fatalf("%s: %d: %v", path, response.Status, response.Body)
	}
	return response.Body
}
func TestMobileSpeedCancelAndDuplicateStart(t *testing.T) {
	s, err := NewSession(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	token := speedCall(t, s, "POST", "/api/groups", "", map[string]string{"name": "Speed", "deviceName": "Test", "platform": "Android"}, 201)["token"].(string)
	var active atomic.Int32
	node := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		active.Add(1)
		defer active.Add(-1)
		<-r.Context().Done()
	}))
	defer node.Close()
	s.speedEndpoint = node.URL + speedtest.Prefix
	started := speedCall(t, s, "POST", "/api/tools/speed/start", token, map[string]any{"serverIds": []string{}}, 200)
	deadline := time.Now().Add(time.Second)
	for active.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if active.Load() == 0 {
		t.Fatal("no request")
	}
	speedCall(t, s, "POST", "/api/tools/speed/start", token, map[string]any{"serverIds": []string{}}, 429)
	speedCall(t, s, "POST", "/api/tools/speed/cancel?id=wrong", token, nil, 404)
	select {
	case <-s.speed.done:
		t.Fatal("a different job ID cancelled the active measurement")
	default:
	}
	speedCall(t, s, "POST", "/api/tools/speed/cancel", token, nil, 200)
	select {
	case <-s.speed.done:
	case <-time.After(time.Second):
		t.Fatal("job leaked")
	}
	result := speedCall(t, s, "GET", "/api/tools/speed/status?id="+started["id"].(string), token, nil, 200)
	if result["state"] != "cancelled" {
		t.Fatal(result)
	}
}
func TestMobileSpeedRealProxyRejectsBadCredentials(t *testing.T) {
	const uuid = "90e3da82-374e-46ef-9099-761d39b86b82"
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := l.Addr().(*net.TCPAddr).Port
	l.Close()
	raw := fmt.Sprintf(`{"log":{"loglevel":"none"},"inbounds":[{"listen":"127.0.0.1","port":%d,"protocol":"vless","settings":{"clients":[{"id":"%s"}],"decryption":"none"}}],"outbounds":[{"protocol":"freedom","settings":{"finalRules":[{"action":"allow","ip":["127.0.0.1"]}]}}]}`, port, uuid)
	config, err := core.LoadConfig("json", strings.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	upstream, err := core.New(config)
	if err != nil {
		t.Fatal(err)
	}
	if err = upstream.Start(); err != nil {
		t.Fatal(err)
	}
	defer upstream.Close()
	s, err := NewSession(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	token := speedCall(t, s, "POST", "/api/groups", "", map[string]string{"name": "Speed", "deviceName": "Test", "platform": "Android"}, 201)["token"].(string)
	node := httptest.NewTLSServer(speedtest.NewHandler(4))
	defer node.Close()
	for _, valid := range []bool{true, false} {
		id := uuid
		if !valid {
			id = "11111111-1111-4111-8111-111111111111"
		}
		profile := fmt.Sprintf(`[{"remarks":"Speed","outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"vless","tag":"vpn","settings":{"vnext":[{"address":"127.0.0.1","port":%d,"users":[{"id":"%s","encryption":"none"}]}]}}],"routing":{"rules":[{"type":"field","network":"tcp,udp","outboundTag":"direct"}]}}]`, port, id)
		speedCall(t, s, "POST", "/api/subscription/import", token, map[string]string{"content": profile}, 200)
		me := speedCall(t, s, "GET", "/api/me", token, nil, 200)
		servers := me["servers"].([]any)
		serverID := servers[len(servers)-1].(map[string]any)["id"].(string)
		prepared, err := s.app.SpeedConfig(token, serverID)
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		transport, cleanup, err := mobileSpeedTransport(ctx, prepared)
		if err != nil {
			cancel()
			t.Fatal(err)
		}
		transport.TLSClientConfig = node.Client().Transport.(*http.Transport).TLSClientConfig.Clone()
		result := speedtest.Measure(ctx, transport, node.URL+speedtest.Prefix, speedtest.Policy{Duration: 100 * time.Millisecond, Download: 32 << 10, Upload: 16 << 10}, func(speedtest.Update) {})
		cleanup()
		cancel()
		if valid && (result.State != "done" || result.Download == nil) {
			t.Fatalf("valid proxy: %+v", result)
		}
		if !valid && (result.State != "error" || result.Download != nil) {
			t.Fatalf("escaped directly: %+v", result)
		}
	}
}
