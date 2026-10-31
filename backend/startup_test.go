package main

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestStartupAuthorizationPersistenceAndFailure(t *testing.T) {
	oldExe, oldQuery, oldChange := desktopExecutable, queryStartup, changeStartup
	t.Cleanup(func() { desktopExecutable, queryStartup, changeStartup = oldExe, oldQuery, oldChange })
	desktopExecutable = "svoi.exe"
	enabled, deny, calls := false, false, 0
	queryStartup = func(string) (bool, error) { return enabled, nil }
	changeStartup = func(_ string, value bool) error {
		calls++
		if deny {
			return fmt.Errorf("permission denied")
		}
		enabled = value
		return nil
	}
	a := newTestApp(t)
	owner := create(t, a)
	member := join(t, a, owner)
	request := func(token, remote, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", "/api/startup", strings.NewReader(body))
		r.RemoteAddr = remote
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		a.handler().ServeHTTP(w, r)
		return w
	}
	for _, entry := range [][2]string{{member, "127.0.0.1:12"}, {owner, "192.0.2.1:12"}} {
		if w := request(entry[0], entry[1], `{"enabled":true}`); w.Code != 403 {
			t.Fatal(w.Code, w.Body.String())
		}
	}
	if calls != 0 {
		t.Fatal("unauthorized task mutation")
	}
	if w := request(owner, "127.0.0.1:12", `{"enabled":true,"zapret":true}`); w.Code != 400 {
		t.Fatal(w.Code)
	}
	if calls != 0 {
		t.Fatal("enabled zapret without saved strategy")
	}
	folder := t.TempDir()
	if err := os.WriteFile(filepath.Join(folder, "general.bat"), []byte(`start "zapret" "%BIN%winws.exe" --wf-tcp=443`), 0600); err != nil {
		t.Fatal(err)
	}
	a.settings.ZapretFolder = folder
	a.zapret = &Zapret{app: a}
	if err := a.rememberZapretStrategy(folder, "general.bat"); err != nil {
		t.Fatal(err)
	}
	if w := request(owner, "127.0.0.1:12", `{"enabled":true,"zapret":true}`); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	restored, err := openApp(a.path)
	if err != nil || !restored.localSettings().StartupZapret || restored.localSettings().ZapretStrategy != "general.bat" || !enabled {
		t.Fatal("startup preferences lost", err)
	}
	deny = true
	if w := request(owner, "127.0.0.1:12", `{"enabled":false,"zapret":false}`); w.Code != 502 || !strings.Contains(w.Body.String(), "permission denied") {
		t.Fatal("task failure hidden", w.Code, w.Body.String())
	}
	if !a.localSettings().StartupZapret || !enabled {
		t.Fatal("failed change altered preferences")
	}
	deny = false
	if w := request(owner, "127.0.0.1:12", `{"enabled":false,"zapret":false}`); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	if enabled || a.localSettings().StartupZapret {
		t.Fatal("disable failed")
	}
	if err := a.rememberZapretStrategy(folder, "../general.bat"); err == nil {
		t.Fatal("accepted traversal")
	}
	if err := a.startSavedZapret(); err != nil {
		t.Fatal("disabled startup launched zapret", err)
	}
	data, _ := json.Marshal(a.localSettings())
	if !strings.Contains(string(data), "general.bat") {
		t.Fatal("last strategy lost after disabling startup")
	}
	blocked := filepath.Join(t.TempDir(), "not-a-directory")
	if err := os.WriteFile(blocked, []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	a.path = filepath.Join(blocked, "groups.json")
	before := calls
	if w := request(owner, "127.0.0.1:12", `{"enabled":true,"zapret":false}`); w.Code == 200 {
		t.Fatal("save failure hidden")
	}
	if enabled || calls != before+2 {
		t.Fatal("task not rolled back after settings write failure")
	}
}

func TestSavedZapretStartupSurfacesFailure(t *testing.T) {
	a := newTestApp(t)
	a.settings.StartupZapret = true
	a.settings.ZapretStrategy = "general-missing.bat"
	a.settings.ZapretFolder = t.TempDir()
	a.zapret = &Zapret{app: a, engine: &Engine{}}
	if err := a.startSavedZapret(); err == nil {
		t.Fatal("missing strategy started")
	}
	if !strings.Contains(a.zapret.lastError, "Автозапуск zapret") {
		t.Fatal("startup error was not exposed to UI")
	}
}

func TestTelegramStartupPersistenceAndRollback(t *testing.T) {
	oldExe, oldQuery, oldChange := desktopExecutable, queryStartup, changeStartup
	t.Cleanup(func() { desktopExecutable, queryStartup, changeStartup = oldExe, oldQuery, oldChange })
	desktopExecutable = "svoi.exe"
	enabled := false
	queryStartup = func(string) (bool, error) { return enabled, nil }
	changeStartup = func(_ string, value bool) error { enabled = value; return nil }
	a := newTestApp(t)
	post := func(body string) error {
		return a.startupAPI(httptest.NewRecorder(), httptest.NewRequest("POST", "/api/startup", strings.NewReader(body)))
	}
	if err := post(`{"enabled":true,"telegramProxy":true}`); err == nil || enabled {
		t.Fatal("missing helper enabled startup")
	}
	binary := filepath.Join(t.TempDir(), "helper.exe")
	if err := os.WriteFile(binary, []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	a.telegramProxy = newTGProxy(binary, filepath.Join(t.TempDir(), "config.json"))
	if err := post(`{"enabled":true,"telegramProxy":true}`); err != nil {
		t.Fatal(err)
	}
	restored, err := openApp(a.path)
	if err != nil || !enabled || !restored.localSettings().StartupTelegramProxy {
		t.Fatal("startup setting lost", err)
	}
	if err := post(`{"enabled":true,"zapret":false}`); err != nil || !a.localSettings().StartupTelegramProxy {
		t.Fatal("legacy request cleared proxy preference", err)
	}
	if err := post(`{"enabled":false}`); err != nil || enabled || a.localSettings().StartupTelegramProxy {
		t.Fatal("app disable left helper autostart enabled", err)
	}
	blocked := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(blocked, []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	a.path = filepath.Join(blocked, "groups.json")
	if err := post(`{"enabled":true,"telegramProxy":true}`); err == nil || enabled || a.localSettings().StartupTelegramProxy {
		t.Fatal("save failure did not roll back task")
	}
}

func TestSavedTelegramStartupFailureVisible(t *testing.T) {
	a := newTestApp(t)
	if err := a.startSavedTelegramProxy(); err != nil {
		t.Fatal(err)
	}
	a.settings.StartupTelegramProxy = true
	a.telegramProxy = newTGProxy("missing", filepath.Join(t.TempDir(), "config.json"))
	if err := a.startSavedTelegramProxy(); err == nil {
		t.Fatal("missing helper started")
	}
	if !strings.Contains(a.telegramProxy.status()["error"].(string), "Автозапуск Telegram-прокси") {
		t.Fatal("startup failure hidden")
	}
}
