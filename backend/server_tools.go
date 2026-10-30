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
	if parts[1] == "extract-nodes" && r.Method == "POST" {
		return a.extractServerNodesAPI(w, r, parts[0])
	}
	a.mu.Lock()
	g, _, err := a.auth(r)
	if err != nil {
		a.mu.Unlock()
		return err
	}
	var server ServerConfig
	found := false
	for _, s := range groupServerViews(g) {
		if s.ID == parts[0] {
			server = s
			found = true
			break
		}
	}
	probeSettings := serverProbeSettings(a.localSettings().Probe, g, server)
	if a.engine != nil {
		server = bindSubscriptionFallback(g, a.engine.Status().Core, server)
	}
	a.mu.Unlock()
	if !found {
		return fail(404, "Сервер не найден")
	}
	if parts[1] == "config" && r.Method == "GET" {
		settings := a.localSettings()
		server.RuntimeApps = &settings.Routing
		server.RuntimeDirectDomains = settings.DirectDomains
		mode := r.URL.Query().Get("mode")
		if mode == "" {
			mode = "local"
		}
		if mode != "local" && mode != "system" && mode != "tun" {
			return fail(400, "Неизвестный режим")
		}
		core := "xray"
		if a.engine != nil {
			core = a.engine.Status().Core
		}
		config, err := buildCoreConfig(core, server, 10808, 10809, mode)
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
		if core == "sing-box" {
			rules, _ = obj(effective["route"])["rules"].([]any)
		} else if core == "mihomo" {
			rules, _ = effective["rules"].([]any)
		}
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
	settings.URL = probeSettings.URL
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
		return fail(503, "Выбранное ядро недоступно. Установите полный пакет SVOI вместе с ядрами.")
	}
	latency, err := probeServer(r.Context(), a.engine, server, settings)
	if err != nil {
		var preparation apiError
		if errors.As(err, &preparation) {
			return preparation
		}
		if errors.Is(err, context.DeadlineExceeded) {
			return fail(504, fmt.Sprintf("Нет ответа за %d с. Можно повторить проверку или подключиться вручную.", settings.TimeoutSeconds))
		}
		return fail(502, "GET-запрос через профиль не прошёл. Сервер, маршрут или адрес проверки недоступен.")
	}
	writeJSON(w, 200, map[string]any{"latency": latency, "checkedAt": time.Now().UTC(), "method": "GET", "url": settings.URL})
	return nil
}

func probeServer(ctx context.Context, base *Engine, server ServerConfig, options ...ProbeSettings) (int64, error) {
	settings := ProbeSettings{}
	if len(options) > 0 {
		settings = options[0]
	} else {
		base.mu.Lock()
		settings.URL = base.checkURL
		base.mu.Unlock()
	}
	if err := validateProbeSettings(&settings); err != nil {
		return 0, err
	}
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	server, err := prepareProviderNodeProbe(server)
	if err != nil {
		return 0, err
	}
	dir, err := os.MkdirTemp(base.dir, "probe-")
	if err != nil {
		return 0, err
	}
	defer os.RemoveAll(dir)
	probe := base.probeEngine(dir)
	probe.checkURL = settings.URL
	// The probe context owns its deadline; avoid racing the HTTP client's
	// independent timer and misclassifying a real timeout as a generic failure.
	probe.checkTimeout = time.Duration(settings.TimeoutSeconds+1) * time.Second
	defer probe.Stop()
	startup, cancelStartup := context.WithTimeout(ctx, 5*time.Second)
	err = probe.startContext(startup, server, "local")
	cancelStartup()
	if err != nil {
		if ctx.Err() != nil {
			return 0, ctx.Err()
		}
		var preparation apiError
		if probe.coreID() != "xray" && errors.As(err, &preparation) && preparation.status == 422 {
			return 0, err
		}
		return 0, fail(503, "Не удалось подготовить выбранное ядро к проверке. Лимит запуска — 5 с; это не результат задержки сервера.")
	}
	ctx, cancel := context.WithTimeout(ctx, time.Duration(settings.TimeoutSeconds)*time.Second)
	defer cancel()
	latency, err := probe.Check(ctx)
	if ctx.Err() != nil {
		return 0, ctx.Err()
	}
	return latency, err
}
