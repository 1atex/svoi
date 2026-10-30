package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestMihomoReadyMarkerAndEnvironment(t *testing.T) {
	t.Setenv("CLASH_CONFIG_STRING", "must-not-override-config")
	t.Setenv("CLASH_POST_DOWN", "must-not-execute")
	directory := filepath.Join(t.TempDir(), "with spaces")
	if err := os.Mkdir(directory, 0700); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("unused")
	ready, cleanup, err := prepareEngineReadiness(cmd, "mihomo", directory)
	if err != nil {
		t.Fatal(err)
	}
	defer cleanup()
	if ready() {
		t.Fatal("ready before post-up")
	}
	for _, env := range cmd.Env {
		if strings.HasPrefix(strings.ToUpper(env), "CLASH_") {
			t.Fatal("inherited override", env)
		}
	}
	command := cmd.Args[len(cmd.Args)-1]
	var shell *exec.Cmd
	if runtime.GOOS == "windows" {
		shell = exec.Command("cmd.exe", "/C", command)
	} else {
		shell = exec.Command("sh", "-c", command)
	}
	shell.Dir = cmd.Dir
	if output, err := shell.CombinedOutput(); err != nil {
		t.Fatalf("marker failed: %v %s", err, output)
	}
	if !ready() {
		t.Fatal("post-up marker not recognized")
	}
	cleanup()
	if ready() {
		t.Fatal("stale marker survived cleanup")
	}
}

func TestNativeCredentialsRedacted(t *testing.T) {
	config := object{"uuid": "private-uuid", "obfs-password": "private-obfs", "private_key": "private-key-material", "url": "https://user:private-password@example.org/path"}
	e := &Engine{redactions: credentialStrings(config)}
	e.Write([]byte("private-uuid private-obfs private-key-material https://user:private-password@example.org/path private-password"))
	for _, line := range e.Status().Logs {
		if strings.Contains(line, "private-") {
			t.Fatal("credential leaked", line)
		}
	}
}
