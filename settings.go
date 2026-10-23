package main

import (
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

type AppRouting struct {
	Mode      string   `json:"mode"`
	Processes []string `json:"processes"`
}
type LocalSettings struct {
	AutoRefresh  bool       `json:"autoRefresh"`
	AutoUpdate   bool       `json:"autoUpdate"`
	AutoDownload bool       `json:"autoDownload"`
	Routing      AppRouting `json:"routing"`
	ZapretFolder string     `json:"zapretFolder"`
}

func (a *App) loadSettings() error {
	a.settings = LocalSettings{AutoRefresh: true, AutoUpdate: true, AutoDownload: true, Routing: AppRouting{Mode: "all", Processes: []string{}}}
	b, err := os.ReadFile(a.path + ".settings.json")
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	return json.Unmarshal(b, &a.settings)
}
func (a *App) localSettings() LocalSettings {
	a.settingsMu.Lock()
	defer a.settingsMu.Unlock()
	s := a.settings
	s.Routing.Processes = append([]string{}, s.Routing.Processes...)
	return s
}
func validateSettings(s *LocalSettings) error {
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
	if r.Method != "GET" && !owner {
		return fail(403, "Доступно владельцу профиля")
	}
	if strings.HasPrefix(r.URL.Path, "/api/updates") {
		if a.updates == nil {
			return fail(503, "Обновления доступны в приложении Windows")
		}
		return a.updates.API(w, r)
	}
	if strings.HasPrefix(r.URL.Path, "/api/zapret") {
		if a.zapret == nil {
			return fail(503, "zapret доступен в приложении Windows")
		}
		return a.zapret.API(w, r, a.localSettings().ZapretFolder)
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
		b, _ := json.MarshalIndent(s, "", "  ")
		path := a.path + ".settings.json"
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			return err
		}
		if err := os.WriteFile(path+".tmp", b, 0600); err != nil {
			return err
		}
		if err := os.Rename(path+".tmp", path); err != nil {
			return err
		}
		a.settings = s
		writeJSON(w, 200, s)
		return nil
	}
	return fail(405, "Метод не поддерживается")
}
