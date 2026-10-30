package main

import (
	"encoding/json"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

type AppRouting struct {
	Mode      string   `json:"mode"`
	Processes []string `json:"processes"`
}
type LocalSettings struct {
	DirectDomains    []string      `json:"directDomains"`
	Probe            ProbeSettings `json:"probe"`
	AutoRefresh      bool          `json:"autoRefresh"`
	AutoUpdate       bool          `json:"autoUpdate"`
	AutoDownload     bool          `json:"autoDownload"`
	Routing          AppRouting    `json:"routing"`
	ZapretFolder     string        `json:"zapretFolder"`
	ZapretAutoUpdate bool          `json:"zapretAutoUpdate"`
	StartupZapret    bool          `json:"startupZapret"`
	ZapretStrategy   string        `json:"zapretStrategy"`
	AutoPauseZapret  bool          `json:"autoPauseZapret"`
}

const defaultProbeURL = "https://www.gstatic.com/generate_204"

type ProbeSettings struct {
	URL            string `json:"url"`
	URLSource      string `json:"urlSource,omitempty"`
	TimeoutSeconds int    `json:"timeoutSeconds"`
	Parallel       int    `json:"parallel"`
}

func (s *ProbeSettings) defaults() {
	if s.URL == "" {
		s.URL = defaultProbeURL
	}
	if s.TimeoutSeconds == 0 {
		s.TimeoutSeconds = 4
	}
	if s.Parallel == 0 {
		s.Parallel = 4
	}
}

func validateProbeSettings(s *ProbeSettings) error {
	s.defaults()
	if s.URLSource != "" && s.URLSource != "subscription" && s.URLSource != "custom" {
		return fail(400, "Неизвестный источник адреса проверки")
	}
	u, err := url.Parse(s.URL)
	if err != nil || len(s.URL) > 2048 || strings.ContainsAny(s.URL, "\r\n\t \\") || u == nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" || u.User != nil || u.Fragment != "" {
		return fail(400, "Укажите HTTP(S)-адрес проверки без логина, пароля и фрагмента")
	}
	if s.TimeoutSeconds < 1 || s.TimeoutSeconds > 15 {
		return fail(400, "Тайм-аут проверки: от 1 до 15 секунд")
	}
	if s.Parallel < 1 || s.Parallel > 10 {
		return fail(400, "Одновременных проверок: от 1 до 10")
	}
	return nil
}

func (a *App) loadSettings() error {
	a.settings = LocalSettings{AutoRefresh: true, AutoUpdate: true, AutoDownload: true, ZapretAutoUpdate: true, Routing: AppRouting{Mode: "all", Processes: []string{}}}
	a.settings.Probe.defaults()
	b, err := os.ReadFile(a.path + ".settings.json")
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if err := json.Unmarshal(b, &a.settings); err != nil {
		return err
	}
	return validateProbeSettings(&a.settings.Probe)
}
func (a *App) localSettings() LocalSettings {
	a.settingsMu.Lock()
	defer a.settingsMu.Unlock()
	s := a.settings
	s.Routing.Processes = append([]string{}, s.Routing.Processes...)
	s.DirectDomains = append([]string{}, s.DirectDomains...)
	return s
}
func validateSettings(s *LocalSettings) error {
	var err error
	s.DirectDomains, err = normalizeDirectDomains(s.DirectDomains)
	if err != nil {
		return err
	}
	if err := validateProbeSettings(&s.Probe); err != nil {
		return err
	}
	if s.Routing.Mode != "all" && s.Routing.Mode != "include" && s.Routing.Mode != "exclude" {
		return fail(400, "Неизвестный режим приложений")
	}
	if len(s.Routing.Processes) > 64 {
		return fail(400, "Не более 64 приложений")
	}
	seen := map[string]bool{}
	names := []string{}
	for _, v := range s.Routing.Processes {
		v = strings.TrimSpace(strings.ReplaceAll(v, `\`, "/"))
		if v == "" {
			continue
		}
		if len(v) > 260 || strings.ContainsAny(v, "\r\n\x00\"*?") {
			return fail(400, "Укажите имя EXE или полный путь без масок")
		}
		if !strings.Contains(v, "/") {
			v = strings.TrimSuffix(v, ".exe")
		}
		if !seen[v] {
			names = append(names, v)
			seen[v] = true
		}
	}
	s.Routing.Processes = names
	if s.Routing.Mode != "all" && len(names) == 0 {
		return fail(400, "Добавьте хотя бы одно приложение")
	}
	if s.ZapretFolder != "" && (!filepath.IsAbs(s.ZapretFolder) || strings.ContainsAny(s.ZapretFolder, "\r\n\x00")) {
		return fail(400, "Укажите полный путь к папке zapret")
	}
	return nil
}
func (a *App) desktopAPI(w http.ResponseWriter, r *http.Request) error {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return fail(403, "Настройки доступны только локально")
	}
	a.mu.Lock()
	_, d, err := a.auth(r)
	owner := err == nil && d.Device.Owner
	a.mu.Unlock()
	if err != nil {
		return err
	}
	if r.Method != "GET" && !owner && r.URL.Path != "/api/dns/benchmark" && r.URL.Path != "/api/tools/site" && !strings.HasPrefix(r.URL.Path, "/api/tools/speed/") {
		return fail(403, "Доступно владельцу профиля")
	}
	if strings.HasPrefix(r.URL.Path, "/api/tools/") {
		if strings.HasPrefix(r.URL.Path, "/api/tools/speed/") {
			return a.speedAPI(w, r)
		}
		return a.siteAPI(w, r)
	}
	if strings.HasPrefix(r.URL.Path, "/api/updates") {
		if a.updates == nil {
			return fail(503, "Обновления доступны в приложении Windows")
		}
		return a.updates.API(w, r)
	}
	if r.URL.Path == "/api/startup" {
		return a.startupAPI(w, r)
	}
	if strings.HasPrefix(r.URL.Path, "/api/zapret") {
		a.networkOp.Lock()
		defer a.networkOp.Unlock()
		if a.zapret == nil {
			return fail(503, "zapret доступен в приложении Windows")
		}
		return a.zapret.API(w, r, a.localSettings().ZapretFolder)
	}
	if strings.HasPrefix(r.URL.Path, "/api/dns") {
		return a.dnsAPI(w, r)
	}
	switch r.Method {
	case "GET":
		writeJSON(w, 200, a.localSettings())
		return nil
	case "PUT":
		var s LocalSettings
		dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32768))
		dec.DisallowUnknownFields()
		if dec.Decode(&s) != nil {
			return fail(400, "Некорректные настройки")
		}
		if err := validateSettings(&s); err != nil {
			return err
		}
		a.settingsMu.Lock()
		defer a.settingsMu.Unlock()
		s.StartupZapret = a.settings.StartupZapret
		s.ZapretStrategy = a.settings.ZapretStrategy
		if err := a.saveSettingsLocked(s); err != nil {
			return err
		}
		writeJSON(w, 200, s)
		return nil
	}
	return fail(405, "Метод не поддерживается")
}
