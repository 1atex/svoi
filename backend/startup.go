package backend

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sync"
)

var desktopExecutable string
var startupMu sync.Mutex
var queryStartup = startupEnabled
var changeStartup = setStartup

func (a *App) startupAPI(w http.ResponseWriter, r *http.Request) error {
	startupMu.Lock()
	defer startupMu.Unlock()
	if desktopExecutable == "" {
		return fail(503, "Автозапуск доступен в приложении SVOI для Windows")
	}
	if r.Method == "POST" {
		var in struct {
			Enabled bool `json:"enabled"`
			Zapret  bool `json:"zapret"`
		}
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&in) != nil || (in.Zapret && !in.Enabled) {
			return fail(400, "Для запуска zapret включите автозапуск SVOI")
		}
		saved := a.localSettings()
		if in.Zapret {
			if a.zapret == nil || saved.ZapretStrategy == "" {
				return fail(400, "Сначала выберите стратегию во вкладке zapret")
			}
			a.zapret.mu.Lock()
			folder := a.zapret.effectiveFolderLocked(saved.ZapretFolder)
			a.zapret.mu.Unlock()
			if _, err := parseZapretStrategy(folder, saved.ZapretStrategy); err != nil {
				return fail(400, "Сохранённая стратегия недоступна. Выберите установленную стратегию zapret")
			}
		}
		previous, err := queryStartup(desktopExecutable)
		if err != nil {
			return startupAPIError("Не удалось проверить автозапуск", err)
		}
		if err := changeStartup(desktopExecutable, in.Enabled); err != nil {
			return startupAPIError("Не удалось изменить автозапуск", err)
		}
		a.settingsMu.Lock()
		defer a.settingsMu.Unlock()
		next := a.settings
		next.StartupZapret = in.Zapret
		if err := a.saveSettingsLocked(next); err != nil {
			if rollback := changeStartup(desktopExecutable, previous); rollback != nil {
				return startupAPIError("Не удалось сохранить настройки; проверьте автозапуск", rollback)
			}
			return fail(500, "Не удалось записать настройки SVOI на диск. Изменение автозапуска отменено")
		}
		writeJSON(w, 200, map[string]any{"enabled": in.Enabled, "zapret": in.Zapret, "strategy": next.ZapretStrategy, "elevated": isElevated()})
		return nil
	}
	if r.Method != "GET" {
		return fail(405, "Метод не поддерживается")
	}
	enabled, err := queryStartup(desktopExecutable)
	if err != nil {
		return startupAPIError("Не удалось проверить автозапуск", err)
	}
	s := a.localSettings()
	writeJSON(w, 200, map[string]any{"enabled": enabled, "zapret": s.StartupZapret, "strategy": s.ZapretStrategy, "elevated": isElevated()})
	return nil
}

func startupAPIError(action string, err error) error {
	if _, ok := err.(apiError); ok {
		return err
	}
	message := []rune(err.Error())
	if len(message) > 800 {
		message = message[:800]
	}
	return fail(502, action+": "+string(message))
}

func (a *App) saveSettingsLocked(s LocalSettings) error {
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
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
	return nil
}

func (a *App) rememberZapretStrategy(folder, strategy string) error {
	if _, err := parseZapretStrategy(folder, strategy); err != nil {
		return err
	}
	a.settingsMu.Lock()
	defer a.settingsMu.Unlock()
	next := a.settings
	next.ZapretStrategy = strategy
	return a.saveSettingsLocked(next)
}

func (a *App) startSavedZapret() error {
	a.networkOp.Lock()
	defer a.networkOp.Unlock()
	s := a.localSettings()
	if !s.StartupZapret {
		return nil
	}
	if a.zapret == nil {
		return fmt.Errorf("zapret недоступен")
	}
	a.zapret.mu.Lock()
	folder := a.zapret.effectiveFolderLocked(s.ZapretFolder)
	a.zapret.mu.Unlock()
	if s.ZapretStrategy == "" {
		return fmt.Errorf("выберите стратегию zapret")
	}
	if err := a.zapret.Start(folder, s.ZapretStrategy); err != nil {
		a.zapret.mu.Lock()
		a.zapret.lastError = "Автозапуск zapret: " + err.Error()
		a.zapret.mu.Unlock()
		return err
	}
	return nil
}
