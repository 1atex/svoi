package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

var releaseRepository = "1atex/svoi"
var releaseAssetPrefix = "SVOI"
var authenticateUpdateInstaller = verifyUpdateAuthenticity

type UpdateStatus struct {
	Current      string                   `json:"current"`
	Version      string                   `json:"version,omitempty"`
	State        string                   `json:"state"`
	Error        string                   `json:"error,omitempty"`
	Notes        string                   `json:"notes,omitempty"`
	Downloaded   int64                    `json:"downloaded"`
	Size         int64                    `json:"size"`
	Repository   string                   `json:"repository"`
	ReleaseURL   string                   `json:"releaseUrl"`
	InstallMode  string                   `json:"installMode"`
	Verification string                   `json:"verification"`
	Notification UpdateNotificationStatus `json:"notification"`
	LastInstall  *UpdateInstallResult     `json:"lastInstall,omitempty"`
	DataBackup   string                   `json:"dataBackup,omitempty"`
}
type releaseAsset struct {
	Name   string `json:"name"`
	URL    string `json:"browser_download_url"`
	Digest string `json:"digest"`
	Size   int64  `json:"size"`
}
type githubRelease struct {
	Tag        string         `json:"tag_name"`
	Draft      bool           `json:"draft"`
	Prerelease bool           `json:"prerelease"`
	Body       string         `json:"body"`
	Assets     []releaseAsset `json:"assets"`
}
type Updater struct {
	mu               sync.Mutex
	status           UpdateStatus
	asset            releaseAsset
	manifestAsset    releaseAsset
	path, dir        string
	busy             bool
	client           *http.Client
	app              *App
	preferences      updatePreferences
	preferencesError string
	notify           func(string, string) error
	background       sync.Once
}

func newUpdater(a *App) *Updater {
	u := &Updater{app: a, dir: filepath.Join(filepath.Dir(a.path), "updates"), notify: showUpdateNotification, status: UpdateStatus{Current: appVersion, State: "idle", Repository: releaseRepository, ReleaseURL: "https://github.com/" + releaseRepository + "/releases", InstallMode: "verified-silent-setup", Verification: "not-downloaded"}, client: &http.Client{Timeout: 10 * time.Minute, CheckRedirect: func(r *http.Request, via []*http.Request) error {
		if len(via) > 5 || r.URL.Scheme != "https" {
			return fmt.Errorf("unsafe update redirect")
		}
		h := r.URL.Hostname()
		if h != "github.com" && h != "release-assets.githubusercontent.com" && h != "objects.githubusercontent.com" {
			return fmt.Errorf("unexpected update host")
		}
		return nil
	}}}
	u.loadUpdatePreferences()
	u.status.LastInstall = readUpdateInstallResult(u.dir)
	return u
}

var versionRE = regexp.MustCompile(`^v?(\d+)\.(\d+)\.(\d+)(?:-(prebeta|beta|rc)\.(\d+))?$`)

func versionParts(s string) ([]int, error) {
	m := versionRE.FindStringSubmatch(s)
	if m == nil {
		return nil, fmt.Errorf("unsupported version")
	}
	v := make([]int, 5)
	for i := 0; i < 3; i++ {
		n, err := strconv.Atoi(m[i+1])
		if err != nil {
			return nil, err
		}
		v[i] = n
	}
	v[3] = 4
	if m[4] != "" {
		v[3] = map[string]int{"prebeta": 1, "beta": 2, "rc": 3}[m[4]]
		n, err := strconv.Atoi(m[5])
		if err != nil {
			return nil, err
		}
		v[4] = n
	}
	return v, nil
}
func newerVersion(candidate, current string) bool {
	a, e := versionParts(candidate)
	b, f := versionParts(current)
	if e != nil || f != nil {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return a[i] > b[i]
		}
	}
	return false
}
func (u *Updater) Status() UpdateStatus {
	u.mu.Lock()
	defer u.mu.Unlock()
	s := u.status
	s.Notification = u.notificationStatusLocked()
	return s
}
func (u *Updater) fail(err error) {
	u.mu.Lock()
	u.status.State = "error"
	u.status.Error = err.Error()
	u.mu.Unlock()
}
func (u *Updater) start(action string) bool {
	u.mu.Lock()
	if u.busy {
		u.mu.Unlock()
		return false
	}
	u.busy = true
	u.status.Error = ""
	u.mu.Unlock()
	go func() {
		defer func() { u.mu.Lock(); u.busy = false; u.mu.Unlock() }()
		var err error
		if action == "check" || action == "background-check" {
			err = u.checkWithNotification(action == "background-check")
		} else {
			err = u.download()
		}
		if err != nil {
			u.fail(err)
		}
	}()
	return true
}
func (u *Updater) check() error {
	return u.checkWithNotification(false)
}
func (u *Updater) checkWithNotification(background bool) error {
	u.mu.Lock()
	u.status.State = "checking"
	u.mu.Unlock()
	if !regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`).MatchString(releaseRepository) {
		return fmt.Errorf("Источник обновлений не настроен")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", "https://api.github.com/repos/"+releaseRepository+"/releases?per_page=30", nil)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "SVOI/"+appVersion)
	resp, err := u.client.Do(req)
	if err != nil {
		return fmt.Errorf("Не удалось проверить обновления: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == 404 {
		return fmt.Errorf("Релизы ещё не опубликованы")
	}
	if resp.StatusCode != 200 {
		return fmt.Errorf("GitHub вернул HTTP %d; повторите проверку позже", resp.StatusCode)
	}
	var releases []githubRelease
	if err = json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(&releases); err != nil {
		return err
	}
	current := appVersion
	var chosen releaseAsset
	var chosenManifest releaseAsset
	notes := ""
	releaseURL := "https://github.com/" + releaseRepository + "/releases"
	for _, r := range releases {
		if r.Draft || (!strings.Contains(appVersion, "-") && (r.Prerelease || strings.Contains(r.Tag, "-"))) || !newerVersion(r.Tag, current) {
			continue
		}
		version := strings.TrimPrefix(r.Tag, "v")
		for _, asset := range r.Assets {
			if asset.Name == releaseAssetPrefix+"-"+version+"-windows-x64-setup.exe" && validUpdateAsset(asset) && strings.Contains(asset.URL, "/releases/download/"+url.PathEscape(r.Tag)+"/") {
				current = version
				chosen = asset
				chosenManifest = releaseAsset{}
				for _, candidate := range r.Assets {
					if validUpdateManifestAsset(candidate, version, r.Tag) {
						chosenManifest = candidate
						break
					}
				}
				notes = r.Body
				releaseURL = "https://github.com/" + releaseRepository + "/releases/tag/" + url.PathEscape(r.Tag)
				break
			}
		}
	}
	u.mu.Lock()
	u.path = ""
	u.asset = chosen
	u.manifestAsset = chosenManifest
	u.status.Downloaded = 0
	u.status.Size = chosen.Size
	u.status.Version = ""
	u.status.Notes = ""
	u.status.State = "current"
	u.status.ReleaseURL = releaseURL
	u.status.Verification = "not-downloaded"
	if chosen.Name != "" {
		u.status.State = "available"
		u.status.Version = current
		u.status.Notes = notes
	}
	u.mu.Unlock()
	if chosen.Name != "" && background {
		u.maybeNotifyUpdate()
	}
	if chosen.Name != "" && u.app.localSettings().AutoDownload && (!background || !u.updateDeferred()) {
		return u.download()
	}
	return nil
}
func validUpdateAsset(a releaseAsset) bool {
	if filepath.Base(a.Name) != a.Name || !regexp.MustCompile(`^`+regexp.QuoteMeta(releaseAssetPrefix)+`-\d+\.\d+\.\d+(?:-(?:prebeta|beta|rc)\.\d+)?-windows-x64-setup\.exe$`).MatchString(a.Name) {
		return false
	}
	parsed, err := url.Parse(a.URL)
	if err != nil || parsed.Scheme != "https" || parsed.Host != "github.com" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || !strings.HasPrefix(parsed.Path, "/"+releaseRepository+"/releases/download/") || filepath.Base(parsed.Path) != a.Name {
		return false
	}
	pathParts := strings.Split(strings.TrimPrefix(parsed.Path, "/"+releaseRepository+"/releases/download/"), "/")
	if len(pathParts) != 2 || pathParts[0] == "" {
		return false
	}
	sum, err := hex.DecodeString(strings.TrimPrefix(a.Digest, "sha256:"))
	return strings.HasPrefix(a.Digest, "sha256:") && err == nil && len(sum) == 32 && a.Size > 0 && a.Size <= 512<<20
}
func (u *Updater) download() error {
	u.mu.Lock()
	asset := u.asset
	manifestAsset := u.manifestAsset
	if !validUpdateAsset(asset) {
		u.mu.Unlock()
		return fmt.Errorf("Нет обновления с подтверждённой SHA-256")
	}
	u.status.State = "downloading"
	u.status.Downloaded = 0
	u.mu.Unlock()
	if err := os.MkdirAll(u.dir, 0700); err != nil {
		return err
	}
	if err := u.stageUpdateManifest(asset, manifestAsset); err != nil {
		return err
	}
	verification := "sha256"
	if manifestAsset.Name != "" {
		verification = "ed25519"
	}
	dest := filepath.Join(u.dir, asset.Name)
	if cached, err := os.Open(dest); err == nil {
		h := sha256.New()
		n, readErr := io.Copy(h, io.LimitReader(cached, asset.Size+1))
		cached.Close()
		if readErr == nil && n == asset.Size && hex.EncodeToString(h.Sum(nil)) == strings.TrimPrefix(asset.Digest, "sha256:") {
			u.mu.Lock()
			u.path, u.status.State, u.status.Downloaded = dest, "ready", n
			u.status.Verification = verification
			u.mu.Unlock()
			return nil
		}
	}
	req, _ := http.NewRequest("GET", asset.URL, nil)
	resp, err := u.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("Загрузка вернула HTTP %d", resp.StatusCode)
	}
	f, err := os.CreateTemp(u.dir, "download-*.part")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	defer f.Close()
	h := sha256.New()
	buf := make([]byte, 128<<10)
	reader := io.LimitReader(resp.Body, asset.Size+1)
	var total int64
	for {
		n, e := reader.Read(buf)
		if n > 0 {
			if _, err = f.Write(buf[:n]); err != nil {
				return err
			}
			h.Write(buf[:n])
			total += int64(n)
			u.mu.Lock()
			u.status.Downloaded = total
			u.mu.Unlock()
		}
		if e == io.EOF {
			break
		}
		if e != nil {
			return e
		}
	}
	if total != asset.Size || hex.EncodeToString(h.Sum(nil)) != strings.TrimPrefix(asset.Digest, "sha256:") {
		return fmt.Errorf("Контрольная сумма обновления не совпала; файл удалён")
	}
	if err = f.Close(); err != nil {
		return err
	}
	if err = os.Rename(f.Name(), dest); err != nil {
		return err
	}
	u.mu.Lock()
	u.path = dest
	u.status.State = "ready"
	u.status.Verification = verification
	u.mu.Unlock()
	return nil
}
func (u *Updater) API(w http.ResponseWriter, r *http.Request) error {
	switch {
	case r.Method == "GET" && r.URL.Path == "/api/updates":
		writeJSON(w, 200, u.Status())
		return nil
	case r.Method == "POST" && r.URL.Path == "/api/updates/check":
		if !u.start("check") {
			return fail(409, "Обновление уже проверяется или скачивается")
		}
	case r.Method == "POST" && r.URL.Path == "/api/updates/download":
		if !u.start("download") {
			return fail(409, "Загрузка уже выполняется")
		}
	case r.Method == "POST" && (r.URL.Path == "/api/updates/snooze" || r.URL.Path == "/api/updates/dismiss"):
		return u.notificationAPI(w, r)
	case r.Method == "POST" && r.URL.Path == "/api/updates/install":
		u.mu.Lock()
		defer u.mu.Unlock()
		if u.busy || u.status.State != "ready" {
			return fail(409, "Обновление ещё не скачано")
		}
		// A repository checksum provides integrity, not publisher authenticity.
		// Verify trust before interrupting an active connection, then recheck in the helper.
		verification, err := authenticateUpdateInstaller(u.path)
		if err != nil {
			u.status.Verification, u.status.Error = "blocked", err.Error()
			return fail(409, err.Error())
		}
		u.status.Verification = verification
		backup, err := u.backupUpdateData()
		if err != nil {
			return fail(500, "Не удалось создать резервную копию профилей: "+err.Error())
		}
		u.status.DataBackup = backup
		if u.app.engine != nil {
			if err := u.app.engine.Stop(); err != nil {
				return err
			}
		}
		if u.app.zapret != nil {
			u.app.zapret.Stop()
		}
		if err := launchUpdateInstaller(u.path, strings.TrimPrefix(u.asset.Digest, "sha256:")); err != nil {
			return err
		}
		u.status.State = "installing"
		time.AfterFunc(500*time.Millisecond, closeDesktop)
	default:
		return fail(404, "Метод обновления не найден")
	}
	writeJSON(w, 202, map[string]bool{"accepted": true})
	return nil
}
