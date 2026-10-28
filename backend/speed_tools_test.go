package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"svoi/internal/speedtest"
	"sync/atomic"
	"testing"
	"time"
)

func TestSpeedCountsRealBytesAndRejectsFalseResults(t *testing.T) {
	s := httptest.NewServer(speedtest.NewHandler(4))
	defer s.Close()
	policy := speedPolicy{Duration: 100 * time.Millisecond, Download: 64 << 10, Upload: 32 << 10}
	r := measureSpeed(context.Background(), &http.Transport{}, s.URL+speedtest.Prefix, policy, func(string, int64, float64) {})
	if r.State != "done" || r.Download == nil || *r.Download <= 0 || r.Upload == nil || *r.Upload <= 0 || r.Latency == nil || r.DownloadBytes != policy.Download || r.UploadBytes != policy.Upload {
		t.Fatalf("invalid result %+v", r)
	}
	if r.DownloadSeconds <= 0 || r.UploadSeconds <= 0 || !r.DownloadCapped || !r.UploadCapped || r.DownloadFullWindow || r.UploadFullWindow || r.Warning == "" {
		t.Fatalf("data-limited short sample presented as full measurement: %+v", r)
	}
	expected := float64(r.DownloadBytes) * 8 / r.DownloadSeconds / 1e6
	if *r.Download != expected {
		t.Fatalf("speed and recorded time disagree: %v vs %v", *r.Download, expected)
	}
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }))
	defer bad.Close()
	r = measureSpeed(context.Background(), &http.Transport{}, bad.URL+"/", policy, func(string, int64, float64) {})
	if r.State != "error" || r.Latency != nil || r.Download != nil || r.Error == "" {
		t.Fatal("false success", r)
	}
}

func TestSpeedCancellationStopsTransfers(t *testing.T) {
	var active atomic.Int32
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		active.Add(1)
		defer active.Add(-1)
		<-r.Context().Done()
	}))
	defer s.Close()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		_, _, _, _ = speedTransfer(ctx, s.Client(), s.URL+"/", "download", time.Minute, 10<<20, func(string, int64, float64) {})
	}()
	deadline := time.Now().Add(time.Second)
	for active.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("transfer did not stop")
	}
	deadline = time.Now().Add(time.Second)
	for active.Load() != 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if active.Load() != 0 {
		t.Fatal("active requests remain")
	}
}

func TestSpeedProfileCannotBypassProxyAndDoesNotMutateOriginal(t *testing.T) {
	original := object{"inbounds": []any{object{"tag": "old-http", "protocol": "http"}}, "outbounds": []any{object{"tag": "direct", "protocol": "freedom"}, object{"tag": "node1", "protocol": "vless"}, object{"tag": "node2", "protocol": "vless"}}, "routing": object{"rules": []any{object{"type": "field", "domain": []string{"full:svoi.space"}, "outboundTag": "direct"}}, "balancers": []any{object{"tag": "auto", "selector": []string{"node", "direct"}, "fallbackTag": "direct"}}}}
	raw, _ := json.Marshal(original)
	copy, err := speedServerConfig(ServerConfig{Profile: raw})
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != string(mustJSON(t, original)) {
		t.Fatal("original modified")
	}
	var p object
	_ = json.Unmarshal(copy.Profile, &p)
	rules := obj(p["routing"])["rules"].([]any)
	gate := obj(rules[0])
	if str(gate["balancerTag"]) != "auto" || str(gate["outboundTag"]) != "" {
		t.Fatal(gate)
	}
	bal := obj(obj(p["routing"])["balancers"].([]any)[0])
	if str(bal["fallbackTag"]) != "node1" || len(bal["selector"].([]any)) != 2 {
		t.Fatal(bal)
	}
	if !strings.Contains(string(copy.Profile), "old-http") {
		t.Fatal("inbound lost")
	}
	_, err = speedServerConfig(ServerConfig{Profile: mustJSON(t, object{"routing": object{"script": "return direct"}})})
	if err == nil {
		t.Fatal("accepted routing.script")
	}
}

func TestSpeedAPIRejectsNestedTUNAndUnknownServers(t *testing.T) {
	a := newTestApp(t)
	token := create(t, a)
	a.engine = &Engine{status: EngineStatus{State: "running", Mode: "tun", Available: true}}
	call := func(body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", "/api/tools/speed/start", strings.NewReader(body))
		r.RemoteAddr = "127.0.0.1:1234"
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		a.handler().ServeHTTP(w, r)
		return w
	}
	expect(t, call(`{"serverIds":[]}`), 409)
	expect(t, call(`{"serverIds":["missing"]}`), 404)
	expect(t, call(`{"serverIds":["1","2","3","4"]}`), 400)
	if a.speed != nil {
		t.Fatal("forbidden test started")
	}
}

type pacedSpeedBody struct {
	io.ReadCloser
	ctx context.Context
}

func (b pacedSpeedBody) Read(p []byte) (int, error) {
	select {
	case <-b.ctx.Done():
		return 0, b.ctx.Err()
	case <-time.After(20 * time.Millisecond):
	}
	return b.ReadCloser.Read(p)
}

type pacedSpeedWriter struct {
	http.ResponseWriter
	ctx context.Context
}

func (w pacedSpeedWriter) Write(p []byte) (int, error) {
	select {
	case <-w.ctx.Done():
		return 0, w.ctx.Err()
	case <-time.After(20 * time.Millisecond):
	}
	return w.ResponseWriter.Write(p)
}
func TestSpeedFullTimeWindowRemainsComparable(t *testing.T) {
	handler := speedtest.NewHandler(4)
	node := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "download") {
			w = pacedSpeedWriter{w, r.Context()}
		}
		if strings.Contains(r.URL.Path, "upload") {
			r.Body = pacedSpeedBody{r.Body, r.Context()}
		}
		handler.ServeHTTP(w, r)
	}))
	defer node.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	result := measureSpeed(ctx, &http.Transport{}, node.URL+speedtest.Prefix, speedPolicy{Duration: 3100 * time.Millisecond, Download: 32 << 20, Upload: 16 << 20}, func(string, int64, float64) {})
	if len(result.DownloadSamples) < 4 || len(result.UploadSamples) < 4 {
		t.Fatal("missing actual transfer history", result)
	}
	if result.State != "done" || !result.DownloadFullWindow || !result.UploadFullWindow || result.DownloadCapped || result.UploadCapped || result.Warning != "" {
		t.Fatalf("full time window misclassified: %+v", result)
	}
}
