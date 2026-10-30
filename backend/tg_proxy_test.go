package main

import (
	"fmt"
	"net"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTGProxySettingsAndRedaction(t *testing.T) {
	path := filepath.Join(t.TempDir(), "proxy", "config.json")
	p := newTGProxy("missing", path)
	if err := validateTGProxyConfig(p.config); err != nil {
		t.Fatal(err)
	}
	if p.status()["link"] != "" {
		t.Fatal("stopped proxy must not offer a connection")
	}
	for i := 0; i < 100; i++ {
		p.record("Secret: " + p.config.Secret)
	}
	if len(p.logs) != 80 || strings.Contains(strings.Join(p.logs, ""), p.config.Secret) {
		t.Fatal("logs are not bounded/redacted")
	}
	for _, port := range []int{0, 80, 65536} {
		r := httptest.NewRequest("POST", "/api/tg-proxy/config", strings.NewReader(fmtTGPort(port)))
		if err := p.API(httptest.NewRecorder(), r); err == nil {
			t.Fatalf("accepted port %d", port)
		}
	}
	r := httptest.NewRequest("POST", "/api/tg-proxy/config", strings.NewReader(`{"port":2443}`))
	if err := p.API(httptest.NewRecorder(), r); err != nil {
		t.Fatal(err)
	}
	reloaded := newTGProxy("missing", path)
	if reloaded.config.Port != 2443 || reloaded.config.Secret != p.config.Secret {
		t.Fatal("configuration was not preserved")
	}
	p.running = true
	if !strings.HasPrefix(p.status()["link"].(string), "tg://proxy?server=127.0.0.1&port=2443&secret=dd") {
		t.Fatal("invalid Telegram link")
	}
}

func fmtTGPort(port int) string { return fmt.Sprintf(`{"port":%d}`, port) }

func TestTGProxyPackagedLifecycle(t *testing.T) {
	binary := os.Getenv("SVOI_TEST_TG_PROXY")
	if binary == "" {
		t.Skip("packaged helper not supplied")
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	p := newTGProxy(binary, filepath.Join(t.TempDir(), "config.json"))
	p.config.Port = port
	if err := p.save(p.config); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { p.Stop() })
	for i := 0; i < 2; i++ {
		if err := p.Start(); err != nil {
			t.Fatalf("start: %v, logs: %v", err, p.logs)
		}
		if p.status()["running"] != true {
			t.Fatal("not running")
		}
		if err := p.API(httptest.NewRecorder(), httptest.NewRequest("POST", "/api/tg-proxy/config", strings.NewReader(`{"port":2443}`))); err == nil {
			t.Fatal("changed port while running")
		}
		if err := p.Stop(); err != nil {
			t.Fatal(err)
		}
		if p.status()["running"] != false {
			t.Fatal("still running")
		}
	}
	listener, err = net.Listen("tcp4", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatal("listener was not released", err)
	}
	defer listener.Close()
	if err := p.Start(); err == nil {
		t.Fatal("reported ready on an occupied port")
	}
	if p.status()["running"] != false {
		t.Fatal("failed start left running state")
	}
}
