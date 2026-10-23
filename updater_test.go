package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestUpdateVersionOrder(t *testing.T) {
	for _, pair := range [][2]string{{"0.4.0-prebeta.2", "0.4.0-prebeta.1"}, {"0.4.0-beta.1", "0.4.0-prebeta.9"}, {"0.4.0-rc.1", "0.4.0-beta.9"}, {"v0.4.0", "0.4.0-rc.9"}, {"0.5.0-prebeta.1", "0.4.0"}} {
		if !newerVersion(pair[0], pair[1]) || newerVersion(pair[1], pair[0]) || newerVersion(pair[0], pair[0]) {
			t.Fatal(pair)
		}
	}
	for _, bad := range []string{"garbage", "0.4.0/evil", "0.4.0-prebeta", "999999999999999999999999999.0.0"} {
		if newerVersion(bad, appVersion) {
			t.Fatal(bad)
		}
	}
}
func updateFixture(body string) releaseAsset {
	sum := sha256.Sum256([]byte(body))
	return releaseAsset{Name: "SVOI-0.4.0-prebeta.2-windows-x64-setup.exe", URL: "https://github.com/" + releaseRepository + "/releases/download/v0.4.0-prebeta.2/setup.exe", Digest: "sha256:" + hex.EncodeToString(sum[:]), Size: int64(len(body))}
}
func TestUpdateAssetTrust(t *testing.T) {
	good := updateFixture("installer")
	if !validUpdateAsset(good) {
		t.Fatal("valid asset rejected")
	}
	for _, url := range []string{"http://github.com/" + releaseRepository + "/releases/download/v1/a", "https://github.com/other/repo/releases/download/v1/a", "https://github.com.evil.test/" + releaseRepository + "/releases/download/v1/a", "https://evil@github.com/" + releaseRepository + "/releases/download/v1/a"} {
		bad := good
		bad.URL = url
		if validUpdateAsset(bad) {
			t.Fatal(url)
		}
	}
	for _, name := range []string{"../setup.exe", `C:\setup.exe`, "setup.exe"} {
		bad := good
		bad.Name = name
		if validUpdateAsset(bad) {
			t.Fatal(name)
		}
	}
	bad := good
	bad.Digest = "sha256:abc"
	if validUpdateAsset(bad) {
		t.Fatal("invalid hash accepted")
	}
}
func TestUpdateDownloadIntegrityAndCache(t *testing.T) {
	for _, body := range []string{"installer", "corrupted", "installer-extra"} {
		t.Run(body, func(t *testing.T) {
			u := newUpdater(newTestApp(t))
			u.asset = updateFixture("installer")
			calls := 0
			u.client = &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) { calls++; return fakeResponse(200, body), nil })}
			err := u.download()
			if body != "installer" {
				if err == nil || u.path != "" {
					t.Fatal("corrupt update accepted")
				}
				files, _ := os.ReadDir(u.dir)
				if len(files) != 0 {
					t.Fatal("temporary file left behind")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			b, err := os.ReadFile(u.path)
			if err != nil || string(b) != body || u.Status().State != "ready" {
				t.Fatal("update not staged")
			}
			if err = u.download(); err != nil || calls != 1 {
				t.Fatal("cached update downloaded again", err, calls)
			}
			os.WriteFile(u.path, []byte("bad"), 0600)
			if err = u.download(); err != nil || calls != 2 {
				t.Fatal("corrupt cache not replaced", err, calls)
			}
		})
	}
}
func TestUpdateCheckSelectsNewestUsableRelease(t *testing.T) {
	a := newTestApp(t)
	a.settings.AutoDownload = false
	u := newUpdater(a)
	releases := []githubRelease{{Tag: "v0.4.0-prebeta.2", Assets: []releaseAsset{updateFixture("installer")}}, {Tag: "v9.0.0", Draft: true, Assets: []releaseAsset{updateFixture("installer")}}, {Tag: "v0.1.0", Assets: []releaseAsset{updateFixture("installer")}}}
	data, _ := json.Marshal(releases)
	u.client = &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "api.github.com" || r.Header.Get("x-hwid") != "" || r.Header.Get("Authorization") != "" {
			t.Fatal("unexpected request")
		}
		return fakeResponse(200, string(data)), nil
	})}
	if err := u.check(); err != nil {
		t.Fatal(err)
	}
	if s := u.Status(); s.State != "available" || s.Version != "0.4.0-prebeta.2" {
		t.Fatal(s)
	}
	if files, _ := filepath.Glob(filepath.Join(u.dir, "*")); len(files) != 0 {
		t.Fatal("download preference ignored")
	}
	for _, host := range []string{"https://evil.test/file", "http://github.com/file"} {
		r, _ := http.NewRequest("GET", host, nil)
		if newUpdater(a).client.CheckRedirect(r, nil) == nil {
			t.Fatal(host)
		}
	}
	if !strings.Contains(u.Status().Repository, "svoi") {
		t.Fatal("wrong repo")
	}
}
