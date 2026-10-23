package main

import (
	"archive/zip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeZapretZIP(t *testing.T, names map[string]string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "archive.zip")
	f, e := os.Create(p)
	if e != nil {
		t.Fatal(e)
	}
	w := zip.NewWriter(f)
	for n, b := range names {
		entry, e := w.Create(n)
		if e != nil {
			t.Fatal(e)
		}
		entry.Write([]byte(b))
	}
	if e = w.Close(); e != nil {
		t.Fatal(e)
	}
	f.Close()
	return p
}
func zapretFixtureFiles() map[string]string {
	return map[string]string{"bin/winws.exe": "test only", "bin/WinDivert.dll": "dll", "bin/WinDivert64.sys": "driver", "service.bat": "@echo off", "general.bat": "start \"test\" \"%BIN%winws.exe\" --wf-tcp=443", "lists/list-general.txt": "example.com", "lists/list-general-user.txt": "default"}
}
func TestZapretZIPIsolation(t *testing.T) {
	for _, bad := range []string{"../escape", "/absolute", `C:\evil.exe`, "folder/../../escape", "folder/file:stream", "NUL.txt", "folder./file", "bin/WINWS.EXE"} {
		t.Run(bad, func(t *testing.T) {
			files := zapretFixtureFiles()
			files[bad] = "bad"
			_, e := extractZapretZIP(context.Background(), writeZapretZIP(t, files), t.TempDir())
			if e == nil {
				t.Fatal("unsafe archive accepted")
			}
		})
	}
	files := map[string]string{}
	for k, v := range zapretFixtureFiles() {
		files["zapret/"+k] = v
	}
	dest := t.TempDir()
	root, e := extractZapretZIP(context.Background(), writeZapretZIP(t, files), dest)
	if e != nil || root != filepath.Join(dest, "zapret") {
		t.Fatal(root, e)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, e = extractZapretZIP(ctx, writeZapretZIP(t, files), t.TempDir()); e == nil {
		t.Fatal("cancellation ignored")
	}
}
func TestZapretDownloadInstallPreservesUserLists(t *testing.T) {
	z := newZapret(newTestApp(t))
	archive := writeZapretZIP(t, zapretFixtureFiles())
	data, _ := os.ReadFile(archive)
	sum := sha256.Sum256(data)
	asset := releaseAsset{Name: "zapret-discord-youtube-1.10.4.zip", URL: "https://github.com/" + zapretRepository + "/releases/download/1.10.4/zapret-discord-youtube-1.10.4.zip", Size: int64(len(data)), Digest: "sha256:" + hex.EncodeToString(sum[:])}
	release := githubRelease{Tag: "1.10.4", Assets: []releaseAsset{asset}}
	payload, _ := json.Marshal(release)
	z.client = &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host == "api.github.com" {
			return fakeResponse(200, string(payload)), nil
		}
		return fakeResponse(200, string(data)), nil
	})}
	if e := z.updatePackage(context.Background()); e != nil {
		t.Fatal(e)
	}
	old := z.managedFolderLocked()
	if z.installed.Version != "1.10.4" {
		t.Fatal(z.installed)
	}
	os.WriteFile(filepath.Join(old, "lists", "list-general-user.txt"), []byte("my.example.com"), 0600)
	release.Tag = "1.10.5"
	payload, _ = json.Marshal(release)
	z.cmd = &exec.Cmd{}
	if e := z.updatePackage(context.Background()); e != nil {
		t.Fatal(e)
	}
	if z.installed.Version != "1.10.4" || z.installed.PendingVersion != "1.10.5" {
		t.Fatal("running installation replaced")
	}
	z.cmd = nil
	if e := z.activatePending(); e != nil {
		t.Fatal(e)
	}
	b, _ := os.ReadFile(filepath.Join(z.managedFolderLocked(), "lists", "list-general-user.txt"))
	if string(b) != "my.example.com" || z.installed.Version != "1.10.5" {
		t.Fatal("custom lists lost")
	}
	restored := newZapret(z.app)
	if restored.installed.Version != "1.10.5" {
		t.Fatal("install pointer lost")
	}
	release.Tag = "1.10.6"
	payload, _ = json.Marshal(release)
	data = []byte("corrupt")
	if e := z.updatePackage(context.Background()); e == nil || z.installed.Version != "1.10.5" {
		t.Fatal("bad update replaced installation")
	}
}
func TestZapretTargetValidation(t *testing.T) {
	for _, target := range []string{"file:///etc/hosts", "http://example.com", "https://user:pass@example.com", "https://example.com:22", "PING:-n 99"} {
		if _, e := parseCheckTarget("test", target); e == nil {
			t.Fatal(target)
		}
	}
	targets, e := standardTargets("")
	if e != nil || len(targets) != 17 {
		t.Fatal(len(targets), e)
	}
	r := runNetworkCheck(context.Background(), checkTarget{Name: "local", URL: "https://127.0.0.1", Host: "127.0.0.1"}, "TLS 1.2", false)
	if r.State == "ok" || !strings.Contains(r.Detail, "non-public") {
		t.Fatal(r)
	}
}
func TestZapretJobCancellationAndBusy(t *testing.T) {
	z := newZapret(newTestApp(t))
	z.client = &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) { <-r.Context().Done(); return nil, r.Context().Err() })}
	if e := z.launchJob("update", nil, false); e != nil {
		t.Fatal(e)
	}
	if e := z.launchJob("diagnostics", nil, false); e == nil {
		t.Fatal("parallel jobs accepted")
	}
	z.Stop()
	if z.job.Busy || z.job.State != "cancelled" {
		t.Fatal(z.job)
	}
}
func TestOfficialZapretPackageOptIn(t *testing.T) {
	if os.Getenv("SVOI_TEST_ZAPRET_NETWORK") != "1" {
		t.Skip("live package check disabled")
	}
	z := newZapret(newTestApp(t))
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	if e := z.updatePackage(ctx); e != nil {
		t.Fatal(e)
	}
	for _, name := range zapretStrategies(z.managedFolderLocked()) {
		if _, e := parseZapretStrategy(z.managedFolderLocked(), name); e != nil {
			t.Fatalf("%s: %v", name, e)
		}
	}
	targets, e := standardTargets(z.managedFolderLocked())
	if e != nil || len(targets) == 0 {
		t.Fatal(e)
	}
	t.Logf("Verified official version %s, %d strategies, %d targets; binaries not executed", z.installed.Version, len(zapretStrategies(z.managedFolderLocked())), len(targets))
}
