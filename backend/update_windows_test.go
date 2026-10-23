//go:build windows

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestInstallerStillVerifiesChecksumWhenParentAlreadyExited(t *testing.T) {
	cmd := exec.Command("cmd.exe", "/c", "exit", "0")
	hideCommand(cmd)
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "not-an-installer.exe")
	if err := os.WriteFile(path, []byte("not executable"), 0600); err != nil {
		t.Fatal(err)
	}
	err := installUpdateAfterExit(path, strings.Repeat("0", 64), cmd.Process.Pid)
	if err == nil || !strings.Contains(err.Error(), "Файл обновления изменён") {
		t.Fatalf("expected checksum rejection after parent exit, got %v", err)
	}
}
