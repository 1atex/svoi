package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

func (a *App) acquireProbeSlot() (ProbeSettings, bool) {
	a.settingsMu.Lock()
	defer a.settingsMu.Unlock()
	settings := a.settings.Probe
	settings.defaults()
	if len(a.probeSlots) >= settings.Parallel {
		return settings, false
	}
	select {
	case a.probeSlots <- struct{}{}:
		return settings, true
	default:
		return settings, false
	}
}

func (a *App) serverToolsAPI(w http.ResponseWriter, r *http.Request) error {
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/api/servers/"), "/")
	if len(parts) != 2 {
		return fail(404, "Метод сервера не найден")
	}
	a.mu.Lock()
	g, _, err := a.auth(r)
	if err != nil {
		a.mu.Unlock()
		return err
	}
	var server ServerConfig
	found := false
	for _, s := range g.Servers {
		if s.ID == parts[0] {
			server = s
			found = true
			break
		}
	}
	a.mu.Unlock()
	if !found {
		return fail(404, "Сервер не найден")
	}
	if parts[1] == "config" && r.Method == "GET" {
		settings := a.localSettings()
		server.RuntimeApps = &settings.Routing
		mode := r.URL.Query().Get("mode")
		if mode == "" {
			mode = "local"
		}
		if mode != "local" && mode != "system" && mode != "tun" {
			return fail(400, "Неизвестный режим")
		}
		config, err := buildXrayConfig(server, 10808, 10809, mode)
		if err != nil {
			return err
		}
		original := server.Outbound
		if len(server.Profile) > 0 {
			original = server.Profile
		}
		var effective object
		_ = json.Unmarshal(config, &effective)
		routing := obj(effective["routing"])
		rules, _ := routing["rules"].([]any)
		balancers, _ := routing["balancers"].([]any)
		writeJSON(w, 200, map[string]any{"server": server.ServerInfo, "original": original, "effective": json.RawMessage(config), "mode": mode, "rules": len(rules), "balancers": len(balancers)})
		return nil
	}
	if (parts[1] != "probe" && parts[1] != "tcp") || r.Method != "POST" {
		return fail(404, "Метод сервера не найден")
	}
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	ip := net.ParseIP(host)
	if a.engine == nil || ip == nil || !ip.IsLoopback() {
		return fail(403, "Проверка доступна только в локальном приложении")
	}
	if err := r.Context().Err(); err != nil {
		return err
	}
	settings, acquired := a.acquireProbeSlot()
	if !acquired {
		return fail(429, fmt.Sprintf("Все %d слотов проверки заняты", settings.Parallel))
	}
	defer func() { <-a.probeSlots }()
	if parts[1] == "tcp" {
		if isHysteriaServer(server.ServerInfo) {
			return fail(400, "Hysteria2 работает через UDP. Используйте проверку задержки через профиль вместо TCP-теста.")
		}
		if server.FullProfile || server.Address == "" || server.Port < 1 || server.Port > 65535 {
			return fail(400, "У полного профиля может быть несколько узлов. Используйте GET-проверку через профиль.")
		}
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		start := time.Now()
		conn, err := (&net.Dialer{}).DialContext(ctx, "tcp", net.JoinHostPort(server.Address, strconv.Itoa(server.Port)))
		if err != nil {
			return fail(502, "TCP-соединение не установлено за 2 секунды или адрес недоступен")
		}
		conn.Close()
		writeJSON(w, 200, map[string]any{"latency": time.Since(start).Milliseconds(), "method": "TCP", "checkedAt": time.Now().UTC()})
		return nil
	}
	if !a.engine.Status().Available {
		return fail(503, "Ядро Xray не найдено")
	}
	latency, err := probeServer(r.Context(), a.engine, server, settings)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			return fail(502, fmt.Sprintf("Нет ответа за %d с. Можно повторить проверку или подключиться вручную.", settings.TimeoutSeconds))
		}
		return fail(502, "GET-запрос через профиль не прошёл. Сервер, маршрут или адрес проверки недоступен.")
	}
	writeJSON(w, 200, map[string]any{"latency": latency, "checkedAt": time.Now().UTC(), "method": "GET", "url": settings.URL})
	return nil
}

func probeServer(ctx context.Context, base *Engine, server ServerConfig, options ...ProbeSettings) (int64, error) {
	settings := ProbeSettings{URL: base.checkURL}
	if len(options) > 0 {
		settings = options[0]
	}
	if err := validateProbeSettings(&settings); err != nil {
		return 0, err
	}
	ctx, cancel := context.WithTimeout(ctx, time.Duration(settings.TimeoutSeconds)*time.Second)
	defer cancel()
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	dir, err := os.MkdirTemp(base.dir, "probe-")
	if err != nil {
		return 0, err
	}
	defer os.RemoveAll(dir)
	probe := &Engine{binary: base.binary, dir: dir, checkURL: settings.URL, checkTimeout: time.Duration(settings.TimeoutSeconds) * time.Second, status: EngineStatus{State: "stopped", Available: true, Logs: []string{}}}
	defer probe.Stop()
	if err = probe.startContext(ctx, server, "local"); err != nil {
		if ctx.Err() != nil {
			return 0, ctx.Err()
		}
		return 0, err
	}
	latency, err := probe.Check(ctx)
	if ctx.Err() != nil {
		return 0, ctx.Err()
	}
	return latency, err
}
