package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// These preferences are independent of settings and profiles. Keys include the
// release channel, so a legacy WebView notification cannot dismiss a Flutter update.
type updateNoticePreference struct {
	Dismissed    bool      `json:"dismissed"`
	SnoozedUntil time.Time `json:"snoozedUntil,omitempty"`
	LastNotified time.Time `json:"lastNotified,omitempty"`
}
type updatePreferences map[string]updateNoticePreference
type UpdateNotificationStatus struct {
	Dismissed    bool   `json:"dismissed"`
	SnoozedUntil string `json:"snoozedUntil,omitempty"`
	LastNotified string `json:"lastNotified,omitempty"`
	Error        string `json:"error,omitempty"`
}

func (u *Updater) preferencesPath() string { return u.app.path + ".update-preferences.json" }
func (u *Updater) noticeKey() string {
	return releaseRepository + "/" + releaseAssetPrefix + "/" + u.status.Version
}
func (u *Updater) loadUpdatePreferences() {
	u.preferences = make(updatePreferences)
	f, err := os.Open(u.preferencesPath())
	if os.IsNotExist(err) {
		return
	}
	if err == nil {
		defer f.Close()
		var info os.FileInfo
		info, err = f.Stat()
		if err == nil && info.Size() > 65536 {
			err = fmt.Errorf("update preferences too large")
		}
		if err == nil {
			decoder := json.NewDecoder(io.LimitReader(f, 65537))
			err = decoder.Decode(&u.preferences)
			if err == nil && decoder.Decode(&struct{}{}) != io.EOF {
				err = fmt.Errorf("invalid update preferences")
			}
		}
	}
	if u.preferences == nil {
		u.preferences = make(updatePreferences)
	}
	if err != nil {
		u.preferencesError = "Не удалось прочитать отложенные уведомления; уведомления отключены до сохранения выбора"
	}
}
func (u *Updater) saveUpdatePreferencesLocked(next updatePreferences) error {
	data, err := json.MarshalIndent(next, "", "  ")
	if err != nil {
		return err
	}
	path := u.preferencesPath()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".update-preferences-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(data)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err = os.Rename(f.Name(), path); err != nil {
		return err
	}
	u.preferences, u.preferencesError = next, ""
	return nil
}
func (u *Updater) notificationStatusLocked() UpdateNotificationStatus {
	p := u.preferences[u.noticeKey()]
	s := UpdateNotificationStatus{Dismissed: p.Dismissed, Error: u.preferencesError}
	if !p.SnoozedUntil.IsZero() {
		s.SnoozedUntil = p.SnoozedUntil.UTC().Format(time.RFC3339)
	}
	if !p.LastNotified.IsZero() {
		s.LastNotified = p.LastNotified.UTC().Format(time.RFC3339)
	}
	return s
}
func (u *Updater) updateDeferred() bool {
	u.mu.Lock()
	defer u.mu.Unlock()
	p := u.preferences[u.noticeKey()]
	return p.Dismissed || time.Now().Before(p.SnoozedUntil)
}
func (u *Updater) copyPreferencesLocked() updatePreferences {
	next := make(updatePreferences, len(u.preferences)+1)
	for k, v := range u.preferences {
		next[k] = v
	}
	return next
}
func (u *Updater) notificationAPI(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Version string `json:"version"`
		Hours   int    `json:"hours"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&in) != nil || decoder.Decode(&struct{}{}) != io.EOF {
		return fail(400, "Укажите версию обновления")
	}
	if r.URL.Path == "/api/updates/snooze" && in.Hours != 24 && in.Hours != 168 {
		return fail(400, "Отложить обновление можно на 24 часа или 7 дней")
	}
	u.mu.Lock()
	defer u.mu.Unlock()
	if in.Version == "" || in.Version != u.status.Version {
		return fail(409, "Версия обновления изменилась; повторите проверку")
	}
	next := u.copyPreferencesLocked()
	p := next[u.noticeKey()]
	if r.URL.Path == "/api/updates/dismiss" {
		p.Dismissed = true
		p.SnoozedUntil = time.Time{}
	} else {
		p.Dismissed = false
		p.SnoozedUntil = time.Now().UTC().Add(time.Duration(in.Hours) * time.Hour)
		p.LastNotified = time.Time{}
	}
	next[u.noticeKey()] = p
	if err := u.saveUpdatePreferencesLocked(next); err != nil {
		return fail(500, "Не удалось сохранить выбор уведомлений")
	}
	writeJSON(w, 200, u.notificationStatusLocked())
	return nil
}

func (u *Updater) maybeNotifyUpdate() {
	u.mu.Lock()
	p := u.preferences[u.noticeKey()]
	if u.status.Version == "" || u.preferencesError != "" || p.Dismissed || time.Now().Before(p.SnoozedUntil) || !p.LastNotified.IsZero() {
		u.mu.Unlock()
		return
	}
	version, executable := u.status.Version, desktopExecutable
	if executable == "" {
		executable, _ = os.Executable()
	}
	// Persist first. Notification suppression by Windows is not an excuse to nag
	// on every login, and multiple starts must not repeatedly show the same release.
	p.LastNotified = time.Now().UTC()
	next := u.copyPreferencesLocked()
	next[u.noticeKey()] = p
	if err := u.saveUpdatePreferencesLocked(next); err != nil {
		u.preferencesError = "Не удалось сохранить уведомление; показ отменён"
		u.mu.Unlock()
		return
	}
	u.mu.Unlock()
	if err := u.notify(version, executable); err != nil {
		u.mu.Lock()
		u.preferencesError = fmt.Sprintf("Уведомление Windows недоступно: %v", err)
		u.mu.Unlock()
	}
}

// Login starts the desktop app via its existing opt-in startup task. A running
// session also checks every six hours, allowing a snooze to expire without logout.
func (u *Updater) startBackgroundCheck() {
	u.background.Do(func() {
		if u.app.localSettings().AutoUpdate {
			u.start("background-check")
		}
		go func() {
			// At logon the network may not be ready yet. Retry transient failures
			// before falling back to the regular six-hour interval.
			for _, delay := range []time.Duration{time.Minute, 4 * time.Minute} {
				timer := time.NewTimer(delay)
				<-timer.C
				if u.app.localSettings().AutoUpdate && u.Status().State == "error" {
					u.start("background-check")
				}
			}
			ticker := time.NewTicker(6 * time.Hour)
			defer ticker.Stop()
			for range ticker.C {
				if u.app.localSettings().AutoUpdate {
					u.start("background-check")
				}
			}
		}()
	})
}
