//go:build windows

package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestWindowsStartupTaskLifecycle(t *testing.T) {
	if !isElevated() {
		if os.Getenv("GITHUB_ACTIONS") == "true" {
			t.Fatal("Windows release CI must verify task registration with administrator rights")
		}
		t.Skip("Task registration requires administrator; covered on Windows CI")
	}
	name := "SVOI-Test-" + secret()
	exe := filepath.Join(t.TempDir(), "SVOI с пробелами", "svoi.exe")
	if err := os.MkdirAll(filepath.Dir(exe), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(exe, []byte("test fixture, never execute"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := startupTaskNamed(exe, "disable", name); err != nil {
			t.Error(err)
		}
	})
	if enabled, err := startupTaskNamed(exe, "query", name); err != nil || enabled {
		t.Fatal(enabled, err)
	}
	if enabled, err := startupTaskNamed(exe, "enable", name); err != nil || !enabled {
		t.Fatal(enabled, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, filepath.Join(os.Getenv("SystemRoot"), "System32", "schtasks.exe"), "/Query", "/TN", name, "/XML")
	hideCommand(cmd)
	xml, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	text := strings.ReplaceAll(string(xml), "\x00", "")
	for _, want := range []string{"InteractiveToken", "HighestAvailable", "LogonTrigger", "--startup", "PT0S", "IgnoreNew"} {
		if !strings.Contains(text, want) {
			t.Fatalf("task missing %s", want)
		}
	}
	if enabled, err := startupTaskNamed(exe, "disable", name); err != nil || enabled {
		t.Fatal(enabled, err)
	}
	if enabled, err := startupTaskNamed(exe, "query", name); err != nil || enabled {
		t.Fatal(enabled, err)
	}
}
