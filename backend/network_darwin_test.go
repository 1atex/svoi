package main

import (
	"os"
	"path/filepath"
	"testing"
)

func init() {
	if core := os.Getenv("SVOI_TEST_CORE"); core != "" {
		helper := filepath.Join(filepath.Dir(filepath.Dir(core)), "svoi-proxy")
		macProxyHelper = func() string { return helper }
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
