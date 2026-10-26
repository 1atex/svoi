package backend

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestPublicIPValidationAndRoutes(t *testing.T) {
	for _, mode := range []string{"stopped", "tun", "system", "local"} {
		t.Run(mode, func(t *testing.T) {
			var direct, proxy atomic.Int32
			target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { direct.Add(1); fmt.Fprint(w, "203.0.113.15") }))
			defer target.Close()
			gateway := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				proxy.Add(1)
				if !r.URL.IsAbs() {
					t.Error("expected proxy request")
				}
				fmt.Fprint(w, "2001:db8::42")
			}))
			defer gateway.Close()
			_, portString, _ := net.SplitHostPort(strings.TrimPrefix(gateway.URL, "http://"))
			port, _ := strconv.Atoi(portString)
			e := &Engine{ipURL: target.URL, status: EngineStatus{State: "running", Mode: mode, HTTPPort: port}}
			if mode == "stopped" {
				e.status.State = "stopped"
			}
			result, err := e.PublicIP(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if mode == "system" || mode == "local" {
				if result.IP != "2001:db8::42" || result.Via != "proxy" || direct.Load() != 0 || proxy.Load() != 1 {
					t.Fatal(result)
				}
			} else if result.IP != "203.0.113.15" || direct.Load() != 1 || proxy.Load() != 0 {
				t.Fatal(result)
			}
		})
	}
	for _, body := range []string{"not an IP", "127.0.0.1", "192.168.1.1", "::", "fe80::1%3", strings.Repeat("a", 100)} {
		t.Run(body[:min(len(body), 20)], func(t *testing.T) {
			target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, body) }))
			defer target.Close()
			e := &Engine{ipURL: target.URL, status: EngineStatus{State: "stopped"}}
			if _, err := e.PublicIP(context.Background()); err == nil {
				t.Fatal("invalid IP accepted")
			}
		})
	}
}

func TestPublicIPStopCancelsRequestAndNeverFallsBack(t *testing.T) {
	entered := make(chan struct{})
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { close(entered); <-r.Context().Done() }))
	defer target.Close()
	e := &Engine{ipURL: target.URL, status: EngineStatus{State: "running", Mode: "tun"}}
	done := make(chan error, 1)
	go func() { _, err := e.PublicIP(context.Background()); done <- err }()
	<-entered
	if err := e.Stop(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("cancelled IP returned")
		}
	case <-time.After(time.Second):
		t.Fatal("IP request blocked stop")
	}

	var reached atomic.Bool
	unreachable := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { reached.Store(true); fmt.Fprint(w, "203.0.113.15") }))
	defer unreachable.Close()
	e.ipURL = unreachable.URL
	e.status = EngineStatus{State: "running", Mode: "system", HTTPPort: 1}
	if _, err := e.PublicIP(context.Background()); err == nil || reached.Load() {
		t.Fatal("proxy lookup leaked to direct route")
	}
}
