package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func init() {
	if core := os.Getenv("SVOI_TEST_CORE"); core != "" {
		helper := filepath.Join(filepath.Dir(filepath.Dir(core)), "svoi-proxy")
		macProxyHelper = func() string { return helper }
	}
}

func TestMacProxyBrokerRetainsProcessWithoutAuthorization(t *testing.T) {
	if _, err := os.Stat(macProxyHelper()); err != nil {
		t.Skip("requires the packaged Swift proxy helper")
	}
	b := &macProxyBroker{}
	t.Cleanup(func() { b.mu.Lock(); defer b.mu.Unlock(); b.closeLocked() })
	first, err := b.call(macProxyRequest{Operation: "ping"})
	if err != nil || first.PID <= 1 || first.AuthorizationRequests != 0 {
		t.Fatalf("initial ping: %+v, %v", first, err)
	}
	for cycle := 0; cycle < 3; cycle++ {
		response, err := b.call(macProxyRequest{Operation: "stop", Directory: t.TempDir()})
		if err != nil || response.PID != first.PID || response.AuthorizationRequests != 0 {
			t.Fatalf("cycle %d replaced helper or requested authorization: %+v, %v", cycle, response, err)
		}
	}
	if _, err := b.call(macProxyRequest{Operation: "invalid"}); err == nil {
		t.Fatal("invalid operation accepted")
	}
	afterError, err := b.call(macProxyRequest{Operation: "ping"})
	if err != nil || afterError.PID != first.PID {
		t.Fatalf("recoverable error replaced helper: %+v, %v", afterError, err)
	}
	p := b.process
	if err := p.cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-p.done:
	case <-time.After(5 * time.Second):
		t.Fatal("helper did not terminate")
	}
	restarted, err := b.call(macProxyRequest{Operation: "ping"})
	if err != nil || restarted.PID == first.PID || restarted.AuthorizationRequests != 0 {
		t.Fatalf("helper did not restart cleanly: %+v, %v", restarted, err)
	}
}

func TestMacPreviewDoesNotEnableUnsupportedTun(t *testing.T) {
	if canCreateTun("unused") {
		t.Fatal("macOS preview must not advertise TUN, even under root")
	}
	e, err := newEngine(testCore(t), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := e.Start(ServerConfig{}, "tun"); err == nil {
		t.Fatal("unsupported TUN accepted")
	}
}

func TestMacImmediateReconnectUsesGracefulShutdown(t *testing.T) {
	e, err := newEngine(testCore(t), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer e.Stop()
	server, err := parseServerURI("vless://90e3da82-374e-46ef-9099-761d39b86b82@127.0.0.1:9?security=none#Stop-test")
	if err != nil {
		t.Fatal(err)
	}
	for cycle := 0; cycle < 20; cycle++ {
		if err := e.Start(server, "local"); err != nil {
			t.Fatal(err)
		}
		process := e.cmd
		if err := e.Stop(); err != nil {
			t.Fatal(err)
		}
		if process.ProcessState == nil || process.ProcessState.ExitCode() != 0 {
			t.Fatalf("cycle %d: core did not exit cleanly: %v", cycle, process.ProcessState)
		}
	}
}
