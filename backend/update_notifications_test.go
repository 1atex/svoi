package main

import (
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func noticeAction(t *testing.T, u *Updater, action, version string, hours int) error {
	t.Helper()
	r := httptest.NewRequest("POST", "/api/updates/"+action, strings.NewReader(fmt.Sprintf(`{"version":%q,"hours":%d}`, version, hours)))
	return u.API(httptest.NewRecorder(), r)
}

func TestUpdateNotificationOncePerVersionAcrossRestart(t *testing.T) {
	a := newTestApp(t)
	u := newUpdater(a)
	u.status.Version = "9.1.0-rc.1"
	calls := 0
	u.notify = func(version, exe string) error {
		calls++
		if version != "9.1.0-rc.1" || exe == "" {
			t.Fatal(version, exe)
		}
		return nil
	}
	u.maybeNotifyUpdate()
	u.maybeNotifyUpdate()
	if calls != 1 {
		t.Fatal("repeated notification", calls)
	}
	restarted := newUpdater(a)
	restarted.status.Version = u.status.Version
	restarted.notify = u.notify
	restarted.maybeNotifyUpdate()
	if calls != 1 || restarted.Status().Notification.LastNotified == "" {
		t.Fatal("notification not persisted", calls)
	}
	restarted.status.Version = "9.1.0-rc.2"
	restarted.notify = func(string, string) error { calls++; return nil }
	restarted.maybeNotifyUpdate()
	if calls != 2 {
		t.Fatal("new version was suppressed")
	}
}

func TestUpdateSnoozeDismissAndNewVersion(t *testing.T) {
	a := newTestApp(t)
	u := newUpdater(a)
	u.status.Version = "9.1.0-rc.1"
	if err := noticeAction(t, u, "snooze", u.status.Version, 24); err != nil {
		t.Fatal(err)
	}
	u = newUpdater(a)
	u.status.Version = "9.1.0-rc.1"
	calls := 0
	u.notify = func(string, string) error { calls++; return nil }
	u.maybeNotifyUpdate()
	if !u.updateDeferred() || calls != 0 {
		t.Fatal("snooze ignored")
	}
	u.mu.Lock()
	p := u.preferences[u.noticeKey()]
	p.SnoozedUntil = time.Now().Add(-time.Second)
	u.preferences[u.noticeKey()] = p
	u.mu.Unlock()
	u.maybeNotifyUpdate()
	if calls != 1 || u.updateDeferred() {
		t.Fatal("expired snooze suppressed notification")
	}
	if err := noticeAction(t, u, "dismiss", u.status.Version, 0); err != nil {
		t.Fatal(err)
	}
	u = newUpdater(a)
	u.status.Version = "9.1.0-rc.1"
	u.notify = func(string, string) error { calls++; return nil }
	u.maybeNotifyUpdate()
	if !u.Status().Notification.Dismissed || calls != 1 {
		t.Fatal("dismiss not persisted")
	}
	u.status.Version = "9.1.0-rc.2"
	u.maybeNotifyUpdate()
	if calls != 2 || u.Status().Notification.Dismissed {
		t.Fatal("new version inherited dismissal")
	}
	if err := noticeAction(t, u, "snooze", "old-version", 24); err == nil {
		t.Fatal("stale dismissal accepted")
	}
	if err := noticeAction(t, u, "snooze", u.status.Version, 1); err == nil {
		t.Fatal("invalid snooze accepted")
	}
}

func TestBrokenNotificationPreferencesDoNotNag(t *testing.T) {
	a := newTestApp(t)
	if err := os.WriteFile(a.path+".update-preferences.json", []byte("broken"), 0600); err != nil {
		t.Fatal(err)
	}
	u := newUpdater(a)
	u.status.Version = "9.1.0-rc.1"
	u.notify = func(string, string) error { t.Fatal("notification with broken preference storage"); return nil }
	u.maybeNotifyUpdate()
	if u.Status().Notification.Error == "" {
		t.Fatal("corruption hidden")
	}
	if err := noticeAction(t, u, "dismiss", u.status.Version, 0); err != nil {
		t.Fatal(err)
	}
	if u.Status().Notification.Error != "" {
		t.Fatal("preference repair did not clear error")
	}
}

func TestUpdateAuthenticityFailureKeepsConnectionRunning(t *testing.T) {
	a := newTestApp(t)
	stopped := false
	a.engine = &Engine{status: EngineStatus{State: "running"}, restoreProxy: func() error { stopped = true; return nil }}
	u := newUpdater(a)
	u.status.State = "ready"
	u.path = filepath.Join(t.TempDir(), "setup.exe")
	previous := authenticateUpdateInstaller
	authenticateUpdateInstaller = func(string) (string, error) { return "blocked", fmt.Errorf("publisher not verified") }
	t.Cleanup(func() { authenticateUpdateInstaller = previous })
	err := u.API(httptest.NewRecorder(), httptest.NewRequest("POST", "/api/updates/install", nil))
	if err == nil || stopped || a.engine.Status().State != "running" {
		t.Fatal("untrusted installer interrupted connection", err)
	}
	if s := u.Status(); s.State != "ready" || s.Verification != "blocked" || s.Error == "" {
		t.Fatal(s)
	}
}

func TestUpdateDataRecoveryCopy(t *testing.T) {
	a := newTestApp(t)
	profiles := []byte(`{"groups":[]}`)
	settings := []byte(`{"autoUpdate":true}`)
	if err := os.WriteFile(a.path, profiles, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(a.path+".settings.json", settings, 0600); err != nil {
		t.Fatal(err)
	}
	u := newUpdater(a)
	dir, err := u.backupUpdateData()
	if err != nil {
		t.Fatal(err)
	}
	for _, pair := range []struct {
		path     string
		expected []byte
	}{{a.path, profiles}, {a.path + ".settings.json", settings}} {
		copied, err := os.ReadFile(filepath.Join(dir, filepath.Base(pair.path)))
		original, _ := os.ReadFile(pair.path)
		if err != nil || string(copied) != string(pair.expected) || string(original) != string(pair.expected) {
			t.Fatal("profile recovery copy mismatch", err)
		}
	}
}
