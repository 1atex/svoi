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
