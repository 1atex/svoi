//go:build windows

package backend

import (
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"testing"
	"time"
)

func TestXrayCleanupHelper(t *testing.T) {
	path := os.Getenv("SVOI_XRAY_CLEANUP_FIXTURE")
	if path == "" {
		return
	}
	interrupt := make(chan os.Signal, 1)
	signal.Notify(interrupt, os.Interrupt)
	if err := os.WriteFile(path, []byte("ready"), 0600); err != nil {
		os.Exit(2)
	}
	<-interrupt
	if err := os.WriteFile(path, []byte("cleaning"), 0600); err != nil {
		os.Exit(2)
	}
	time.Sleep(300 * time.Millisecond)
	if err := os.WriteFile(path, []byte("clean"), 0600); err != nil {
		os.Exit(2)
	}
	os.Exit(0)
}

func TestStopWaitsForWindowsCleanup(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cleanup.txt")
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(exe, "-test.run=^TestXrayCleanupHelper$")
	cmd.Env = append(os.Environ(), "SVOI_XRAY_CLEANUP_FIXTURE="+path)
	prepareXrayCommand(cmd)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { _ = cmd.Wait(); close(done) }()
	t.Cleanup(func() { _ = cmd.Process.Kill(); <-done })
	waitFor := func(want string) {
		t.Helper()
		deadline := time.Now().Add(4 * time.Second)
		for time.Now().Before(deadline) {
			data, _ := os.ReadFile(path)
			if string(data) == want {
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatalf("cleanup never reached %s", want)
	}
	waitFor("ready")
	e := &Engine{cmd: cmd, done: done, status: EngineStatus{State: "running"}}
	stopped := make(chan error, 1)
	go func() { stopped <- e.Stop() }()
	waitFor("cleaning")
	if got := e.Status().State; got != "stopping" {
		t.Fatalf("premature state: %s", got)
	}
	select {
	case err := <-stopped:
		t.Fatalf("stop completed before cleanup: %v", err)
	default:
	}
	if err := <-stopped; err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(path)
	if string(data) != "clean" || cmd.ProcessState.ExitCode() != 0 || e.Status().State != "stopped" {
		t.Fatalf("unclean shutdown: %q, %v", data, cmd.ProcessState)
	}
}
