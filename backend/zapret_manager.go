package backend

import (
	"archive/zip"
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
	"strings"
	"time"
)

const zapretRepository = "Flowseal/zapret-discord-youtube"

type zapretInstall struct {
	Version        string `json:"version"`
	Directory      string `json:"directory"`
	PendingVersion string `json:"pendingVersion,omitempty"`
	Pending        string `json:"pending,omitempty"`
}
type CheckResult struct {
	Strategy string `json:"strategy"`
	Target   string `json:"target"`
	Check    string `json:"check"`
	State    string `json:"state"`
	Detail   string `json:"detail"`
	Millis   int64  `json:"millis,omitempty"`
}
type ZapretJob struct {
	ResultCount int           `json:"resultCount"`
	Successful  int           `json:"successful"`
	Sweep       bool          `json:"sweep"`
	Busy        bool          `json:"busy"`
	Kind        string        `json:"kind"`
	State       string        `json:"state"`
	Message     string        `json:"message"`
	Completed   int           `json:"completed"`
	Total       int           `json:"total"`
	Downloaded  int64         `json:"downloaded"`
	Size        int64         `json:"size"`
	Results     []CheckResult `json:"results"`
}

func newZapret(a *App) *Zapret {
	z := &Zapret{app: a, engine: a.engine, root: filepath.Join(filepath.Dir(a.path), "zapret"), client: newUpdater(a).client, job: ZapretJob{State: "idle", Results: []CheckResult{}}}
	if b, err := os.ReadFile(filepath.Join(z.root, "installed.json")); err == nil {
		json.Unmarshal(b, &z.installed)
	}
	for _, name := range []string{z.installed.Directory, z.installed.Pending} {
		if name != "" && !managedDirectoryName(name) {
			z.installed = zapretInstall{}
			break
		}
	}
	if err := z.activatePending(); err != nil {
		z.lastError = err.Error()
	}
	return z
}
func managedDirectoryName(s string) bool {
	return regexp.MustCompile(`^release-[a-zA-Z0-9._-]+$`).MatchString(s) && filepath.Base(s) == s
}
func (z *Zapret) managedFolderLocked() string {
	if z.installed.Directory == "" {
		return ""
	}
	return filepath.Join(z.root, z.installed.Directory)
}
func (z *Zapret) effectiveFolderLocked(external string) string {
	if external != "" {
		return external
	}
	return z.managedFolderLocked()
}
func (z *Zapret) saveInstallLocked(next zapretInstall) error {
	if err := os.MkdirAll(z.root, 0700); err != nil {
		return err
	}
	b, _ := json.MarshalIndent(next, "", "  ")
	p := filepath.Join(z.root, "installed.json")
	if err := os.WriteFile(p+".tmp", b, 0600); err != nil {
		return err
	}
	if err := os.Rename(p+".tmp", p); err != nil {
		return err
	}
	z.installed = next
	return nil
}
func (z *Zapret) activatePending() error {
	z.mu.Lock()
	defer z.mu.Unlock()
	if z.installed.Pending == "" || z.cmd != nil {
		return nil
	}
	dest := filepath.Join(z.root, z.installed.Pending)
	if err := validateZapretFolder(dest); err != nil {
		return err
	}
	if old := z.managedFolderLocked(); old != "" {
		if err := copyZapretUserFiles(old, dest); err != nil {
			return err
		}
	}
	next := z.installed
	next.Directory, next.Version = next.Pending, next.PendingVersion
	next.Pending, next.PendingVersion = "", ""
	return z.saveInstallLocked(next)
}
func copyZapretUserFiles(old, dest string) error {
	for _, name := range []string{"lists/list-general-user.txt", "lists/list-exclude-user.txt", "lists/ipset-exclude-user.txt", "utils/targets.txt"} {
		b, err := os.ReadFile(filepath.Join(old, name))
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return err
		}
		if len(b) > 4<<20 {
			return fmt.Errorf("Слишком большой пользовательский файл: %s", name)
		}
		target := filepath.Join(dest, name)
		if err = os.MkdirAll(filepath.Dir(target), 0700); err != nil {
			return err
		}
		if err = os.WriteFile(target, b, 0600); err != nil {
			return err
		}
	}
	return nil
}
func (z *Zapret) launchJob(kind string, strategies []string, sweep bool) error {
	if kind != "update" && kind != "diagnostics" && kind != "standard" && kind != "dpi" {
		return fail(400, "Неизвестная проверка")
	}
	if sweep && (kind != "standard" && kind != "dpi") {
		return fail(400, "Перебор доступен только для сетевых тестов")
	}
	z.op.Lock()
	defer z.op.Unlock()
	z.mu.Lock()
	defer z.mu.Unlock()
	if z.job.Busy {
		return fail(409, "Уже выполняется задача zapret")
	}
	folder := z.effectiveFolderLocked(z.app.localSettings().ZapretFolder)
	if sweep {
		if !isElevated() {
			return fail(409, "Для перебора стратегий запустите SVOI от администратора")
		}
		if z.engine != nil {
			if s := z.engine.Status(); s.State == "running" {
				return fail(409, "Отключите VPN перед перебором стратегий")
			}
		}
		if z.cmd == nil && externalZapretRunning() {
			return fail(409, "Сначала остановите сторонний winws через его лаунчер")
		}
		allowed := zapretStrategies(folder)
		if len(strategies) == 0 {
			strategies = allowed
		}
		if len(strategies) == 0 || len(strategies) > 64 {
			return fail(400, "Нет стратегий для проверки")
		}
		seen := map[string]bool{}
		for _, s := range strategies {
			found := false
			for _, a := range allowed {
				if a == s {
					found = true
				}
			}
			if !found || seen[s] {
				return fail(400, "Некорректный список стратегий")
			}
			seen[s] = true
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Minute)
	z.cancel = cancel
	done := make(chan struct{})
	z.jobDone = done
	z.job = ZapretJob{Busy: true, Kind: kind, Sweep: sweep, State: "running", Message: "Подготовка…", Results: []CheckResult{}}
	z.resultsRevision++
	go func() {
		defer cancel()
		var err error
		switch kind {
		case "update":
			err = z.updatePackage(ctx)
		case "diagnostics":
			err = z.diagnostics(ctx, folder)
		default:
			err = z.checkNetwork(ctx, folder, kind, strategies, sweep)
		}
		z.mu.Lock()
		z.job.Busy = false
		z.job.State = "done"
		if err != nil {
			z.job.State = "error"
			z.job.Message = err.Error()
		}
		if ctx.Err() != nil {
			z.job.State = "cancelled"
			z.job.Message = "Проверка остановлена"
		}
		z.cancel = nil
		z.mu.Unlock()
		close(done)
	}()
	return nil
}
func (z *Zapret) message(s string) { z.mu.Lock(); z.job.Message = s; z.mu.Unlock() }
func (z *Zapret) blocksVPN(mode string) bool {
	z.mu.Lock()
	defer z.mu.Unlock()
	return z.job.Busy && z.job.Sweep || mode == "tun" && z.cmd != nil
}
func (z *Zapret) addResult(r CheckResult) {
	z.mu.Lock()
	defer z.mu.Unlock()
	z.job.Results = append(z.job.Results, r)
	z.resultsRevision++
	z.job.ResultCount++
	if r.State == "ok" {
		z.job.Successful++
	}
	z.job.Completed++
}
func validZapretAsset(a releaseAsset) bool {
	u, err := url.Parse(a.URL)
	sum, e := hex.DecodeString(strings.TrimPrefix(a.Digest, "sha256:"))
	return err == nil && u.Scheme == "https" && u.Host == "github.com" && u.User == nil && strings.HasPrefix(u.Path, "/"+zapretRepository+"/releases/download/") && filepath.Base(a.Name) == a.Name && strings.HasSuffix(a.Name, ".zip") && strings.HasPrefix(a.Name, "zapret-discord-youtube-") && strings.HasPrefix(a.Digest, "sha256:") && e == nil && len(sum) == 32 && a.Size > 0 && a.Size <= 64<<20
}
func (z *Zapret) updatePackage(ctx context.Context) error {
	z.message("Проверяем официальный релиз Flowseal…")
	req, _ := http.NewRequestWithContext(ctx, "GET", "https://api.github.com/repos/"+zapretRepository+"/releases/latest", nil)
	req.Header.Set("User-Agent", "SVOI/"+appVersion)
	resp, err := z.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("GitHub: HTTP %d", resp.StatusCode)
	}
	var release githubRelease
	if err = json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(&release); err != nil {
		return err
	}
	if release.Draft || release.Prerelease || !regexp.MustCompile(`^v?\d+\.\d+\.\d+(?:\.\d+)?$`).MatchString(release.Tag) {
		return fmt.Errorf("Неподдерживаемый релиз zapret")
	}
	z.mu.Lock()
	installed := z.installed
	z.mu.Unlock()
	if installed.Version == release.Tag && validateZapretFolder(filepath.Join(z.root, installed.Directory)) == nil {
		z.message("Установлена актуальная версия " + release.Tag)
		return nil
	}
	if installed.PendingVersion == release.Tag {
		z.message("Обновление скачано; отключите zapret для применения")
		return nil
	}
	var asset releaseAsset
	for _, a := range release.Assets {
		if validZapretAsset(a) {
			asset = a
			break
		}
	}
	if asset.Name == "" {
		return fmt.Errorf("В релизе нет ZIP с SHA-256")
	}
	if err = os.MkdirAll(z.root, 0700); err != nil {
		return err
	}
	archive, err := os.CreateTemp(z.root, "download-*.zip")
	if err != nil {
		return err
	}
	defer os.Remove(archive.Name())
	defer archive.Close()
	z.mu.Lock()
	z.job.Size = asset.Size
	z.job.Message = "Скачиваем zapret " + release.Tag
	z.mu.Unlock()
	req, _ = http.NewRequestWithContext(ctx, "GET", asset.URL, nil)
	response, err := z.client.Do(req)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return fmt.Errorf("Загрузка: HTTP %d", response.StatusCode)
	}
	hash := sha256.New()
	reader := io.LimitReader(response.Body, asset.Size+1)
	buf := make([]byte, 64<<10)
	var size int64
	for {
		n, e := reader.Read(buf)
		if n > 0 {
			if _, err = archive.Write(buf[:n]); err != nil {
				return err
			}
			hash.Write(buf[:n])
			size += int64(n)
			z.mu.Lock()
			z.job.Downloaded = size
			z.mu.Unlock()
		}
		if e == io.EOF {
			break
		}
		if e != nil {
			return e
		}
	}
	if size != asset.Size || hex.EncodeToString(hash.Sum(nil)) != strings.TrimPrefix(asset.Digest, "sha256:") {
		return fmt.Errorf("Контрольная сумма zapret не совпала")
	}
	if err = archive.Close(); err != nil {
		return err
	}
	z.message("Распаковываем и проверяем состав…")
	stage, err := os.MkdirTemp(z.root, "unpack-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	root, err := extractZapretZIP(ctx, archive.Name(), stage)
	if err != nil {
		return err
	}
	if err = validateZapretFolder(root); err != nil {
		return err
	}
	if err = ctx.Err(); err != nil {
		return err
	}

	name := "release-" + release.Tag + "-" + filepath.Base(stage)[len("unpack-"):]
	if err = os.Rename(root, filepath.Join(z.root, name)); err != nil {
		return err
	}
	z.mu.Lock()
	next := z.installed
	next.Pending = name
	next.PendingVersion = release.Tag
	err = z.saveInstallLocked(next)
	running := z.cmd != nil
	z.mu.Unlock()
	if err != nil {
		return err
	}
	if !running {
		if err = z.activatePending(); err != nil {
			return err
		}
		z.message("zapret " + release.Tag + " установлен")
	} else {
		z.message("zapret " + release.Tag + " скачан; применится после остановки")
	}
	return nil
}
func validateZapretFolder(root string) error {
	for _, p := range []string{"bin/winws.exe", "bin/WinDivert.dll", "bin/WinDivert64.sys", "service.bat", "lists/list-general.txt"} {
		f, e := os.Stat(filepath.Join(root, p))
		if e != nil || f.IsDir() || f.Size() == 0 {
			return fmt.Errorf("В архиве отсутствует %s", p)
		}
	}
	if len(zapretStrategies(root)) == 0 {
		return fmt.Errorf("В архиве нет general*.bat")
	}
	return nil
}
func extractZapretZIP(ctx context.Context, archive, dest string) (string, error) {
	r, err := zip.OpenReader(archive)
	if err != nil {
		return "", err
	}
	defer r.Close()
	if len(r.File) > 4096 {
		return "", fmt.Errorf("Слишком много файлов")
	}
	seen := map[string]bool{}
	var total int64
	for _, f := range r.File {
		if err = ctx.Err(); err != nil {
			return "", err
		}
		name := strings.ReplaceAll(f.Name, "\\", "/")
		clean := filepath.Clean(filepath.FromSlash(name))
		parts := strings.Split(strings.TrimSuffix(name, "/"), "/")
		bad := name == "" || strings.HasPrefix(name, "/") || filepath.IsAbs(clean) || strings.Contains(name, ":") || f.Mode()&os.ModeSymlink != 0
		for _, p := range parts {
			base := strings.ToUpper(strings.Split(p, ".")[0])
			if p == ".." || p == "." || p == "" || strings.HasSuffix(p, ".") || strings.HasSuffix(p, " ") || regexp.MustCompile(`^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$`).MatchString(base) {
				bad = true
			}
		}
		key := strings.ToLower(clean)
		if bad || seen[key] {
			return "", fmt.Errorf("Небезопасный путь ZIP")
		}
		seen[key] = true
		total += int64(f.UncompressedSize64)
		if f.UncompressedSize64 > 64<<20 || total > 256<<20 {
			return "", fmt.Errorf("Распакованный архив слишком большой")
		}
		path := filepath.Join(dest, clean)
		rel, e := filepath.Rel(dest, path)
		if e != nil || strings.HasPrefix(rel, "..") {
			return "", fmt.Errorf("Путь вне каталога")
		}
		if f.FileInfo().IsDir() {
			if e = os.MkdirAll(path, 0700); e != nil {
				return "", e
			}
			continue
		}
		if e = os.MkdirAll(filepath.Dir(path), 0700); e != nil {
			return "", e
		}
		src, e := f.Open()
		if e != nil {
			return "", e
		}
		dst, e := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if e != nil {
			src.Close()
			return "", e
		}
		n, e := io.Copy(dst, io.LimitReader(src, 64<<20+1))
		ce := dst.Close()
		src.Close()
		if e != nil {
			return "", e
		}
		if ce != nil {
			return "", ce
		}
		if n > 64<<20 {
			return "", fmt.Errorf("Файл слишком большой")
		}
	}
	if validateZapretFolder(dest) == nil {
		return dest, nil
	}
	entries, _ := os.ReadDir(dest)
	for _, e := range entries {
		if e.IsDir() {
			p := filepath.Join(dest, e.Name())
			if validateZapretFolder(p) == nil {
				return p, nil
			}
		}
	}
	return "", fmt.Errorf("Архив не содержит ожидаемую структуру zapret")
}
