package main

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

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
	if parts[1] != "probe" || r.Method != "POST" {
		return fail(404, "Метод сервера не найден")
	}
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	ip := net.ParseIP(host)
	if a.engine == nil || ip == nil || !ip.IsLoopback() {
		return fail(403, "Проверка доступна только в локальном приложении")
	}
	select {
	case a.probeSlots <- struct{}{}:
		defer func() { <-a.probeSlots }()
	case <-r.Context().Done():
		return r.Context().Err()
	default:
		return fail(429, "Все четыре слота проверки заняты")
	}
	if !a.engine.Status().Available {
		return fail(503, "Ядро Xray не найдено")
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	latency, err := probeServer(ctx, a.engine, server)
	if err != nil {
		return fail(502, "Профиль не прошёл HTTPS-проверку. Сервер, маршрут или адрес проверки недоступен.")
	}
	writeJSON(w, 200, map[string]any{"latency": latency, "checkedAt": time.Now().UTC(), "method": "HTTPS", "url": a.engine.checkURL})
	return nil
}

// A separate local-only core leaves the active engine, adapter and OS proxy alone.
func probeServer(ctx context.Context, base *Engine, server ServerConfig) (int64, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	dir, err := os.MkdirTemp(base.dir, "probe-")
	if err != nil {
		return 0, err
	}
	defer os.RemoveAll(dir)
	probe := &Engine{binary: base.binary, dir: dir, checkURL: base.checkURL, status: EngineStatus{State: "stopped", Available: true, Logs: []string{}}}
	defer probe.Stop()
	if err = probe.startContext(ctx, server, "local"); err != nil {
		return 0, err
	}
	return probe.Check(ctx)
}
