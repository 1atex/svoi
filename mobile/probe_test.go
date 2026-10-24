package mobile

import (
	"context"
	"encoding/json"
	"errors"
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

func TestProbeCancellationClosesRequest(t *testing.T) {
	entered, closed := make(chan struct{}), make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(entered)
		<-r.Context().Done()
		close(closed)
	}))
	defer srv.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result := make(chan error, 1)
	config := probeFixture(t, srv.URL)
	go func() { _, err := probeConfig(ctx, config, srv.URL); result <- err }()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("request did not arrive")
	}
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("cancel did not stop probe")
	}
	select {
	case <-closed:
	case <-time.After(time.Second):
		t.Fatal("probe left an open connection")
	}
}

func TestCancelledProbeNeverLoadsProfile(t *testing.T) {
	p := (&Session{}).NewProbe("unused", "unused")
	p.Cancel()
	if _, err := p.Run(); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if len(probeSlots) != 0 {
		t.Fatal("cancelled probe occupied a slot")
	}
	if _, err := p.Run(); err == nil {
		t.Fatal("a probe cannot be reused")
	}
}
