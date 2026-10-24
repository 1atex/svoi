package mobile

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"sync"
	"testing"
	"time"
)

func probeFixture(t *testing.T, target string) string {
	t.Helper()
	u, _ := url.Parse(target)
	_, port, _ := net.SplitHostPort(u.Host)
	p, _ := strconv.Atoi(port)
	config := map[string]any{
		"inbounds": []any{map[string]any{"tag": "probe-in", "protocol": "http", "listen": "127.0.0.1", "port": p}},
		"outbounds": []any{
			map[string]any{"tag": "deny", "protocol": "blackhole"},
			map[string]any{"tag": "direct", "protocol": "freedom", "settings": map[string]any{"finalRules": []any{map[string]any{"action": "allow", "ip": []string{"127.0.0.1"}, "port": port, "network": "tcp"}}}},
		},
		"routing": map[string]any{"rules": []any{map[string]any{"type": "field", "inboundTag": []string{"probe-in"}, "outboundTag": "direct"}}},
	}
	data, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestProbesPreserveRoutingWithoutBindingPorts(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	defer srv.Close()
	config := probeFixture(t, srv.URL)
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), time.Second*3)
			defer cancel()
			if _, err := probeConfig(ctx, config, srv.URL); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
}

func TestProbeTimeoutAndInvalidHTTPResponse(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/stall" {
			<-r.Context().Done()
			return
		}
		w.WriteHeader(http.StatusFound)
	}))
	defer srv.Close()
	config := probeFixture(t, srv.URL)
	for _, path := range []string{"/stall", "/redirect"} {
		ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
		started := time.Now()
		_, err := probeConfig(ctx, config, srv.URL+path)
		cancel()
		if err == nil {
			t.Fatal("invalid probe reported success")
		}
		if time.Since(started) > time.Second {
			t.Fatal("probe did not release resources within deadline")
		}
	}
}
