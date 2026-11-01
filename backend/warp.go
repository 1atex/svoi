package main

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

type warpStatus struct {
	Installed          bool   `json:"installed"`
	State              string `json:"state"`
	Error              string `json:"error,omitempty"`
	VPNRunning         bool   `json:"vpnRunning"`
	ZapretRunning      bool   `json:"zapretRunning"`
	ComponentAvailable bool   `json:"componentAvailable"`
	InstallerOpened    bool   `json:"installerOpened"`
}

type warpClient struct {
	binary string
	run    func(context.Context, ...string) (string, error)
}

func newWarpClient() *warpClient {
	if runtime.GOOS != "windows" && runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
		return nil
	}
	w := &warpClient{}
	for _, root := range []string{os.Getenv("ProgramW6432"), os.Getenv("ProgramFiles")} {
		if root == "" {
			continue
		}
		candidate := filepath.Join(root, "Cloudflare", "Cloudflare WARP", "warp-cli.exe")
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			w.binary = candidate
			break
		}
	}
	if w.binary == "" {
		paths := map[string][]string{"darwin": {"/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli", "/usr/local/bin/warp-cli"}, "linux": {"/usr/bin/warp-cli", "/bin/warp-cli"}}
		for _, path := range paths[runtime.GOOS] {
			if info, err := os.Stat(path); err == nil && !info.IsDir() {
				w.binary = path
				break
			}
		}
	}
	w.run = func(ctx context.Context, args ...string) (string, error) {
		cmd := exec.CommandContext(ctx, w.binary, args...)
		cmd.WaitDelay = time.Second
		hideCommand(cmd)
		out, err := cmd.CombinedOutput()
		return string(out), err
	}
	return w
}

func parseWarpStatus(text string) string {
	text = strings.ToLower(strings.TrimSpace(text))
	if strings.Contains(text, "missing registration") || strings.Contains(text, "registration missing") || strings.Contains(text, "not registered") {
		return "unregistered"
	}
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		for _, prefix := range []string{"status update:", "status:"} {
			if strings.HasPrefix(line, prefix) {
				line = strings.TrimSpace(strings.TrimPrefix(line, prefix))
				break
			}
		}
		switch line {
		case "disconnected", "connected", "connecting", "disconnecting", "unregistered":
			return line
		}
	}
	return "unknown"
}

func (w *warpClient) status(ctx context.Context) warpStatus {
	if w == nil || w.binary == "" {
		return warpStatus{State: "not-installed"}
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	text, err := w.run(ctx, "status")
	state := parseWarpStatus(text)
	s := warpStatus{Installed: true, State: state}
	if state == "unregistered" {
		return s
	}
	if err != nil || state == "unknown" {
		s.State = "unknown"
		s.Error = "Не удалось получить состояние WARP. Откройте официальный клиент, завершите первоначальную настройку и повторите проверку."
		if ctx.Err() != nil {
			s.Error = "Служба WARP не ответила за 3 секунды. Откройте официальный клиент и повторите проверку."
		}
	}
	return s
}

func warpActive(state string) bool {
	return state == "connected" || state == "connecting" || state == "disconnecting"
}

func (a *App) warpStatus(ctx context.Context) warpStatus {
	s := a.warp.status(ctx)
	path, _ := warpComponentPath()
	if info, err := os.Stat(path); err == nil && !info.IsDir() {
		s.ComponentAvailable = true
	}
	s.InstallerOpened = time.Since(a.warpInstallerOpened) < 30*time.Second
	if a.engine != nil {
		state := a.engine.snapshot(false).State
		s.VPNRunning = state == "running" || state == "starting" || state == "stopping"
	}
	s.ZapretRunning = externalZapretRunning()
	if a.zapret != nil && a.zapret.blocksVPN("tun") {
		s.ZapretRunning = true
	}
	return s
}

func (a *App) warpBlocksConnection(ctx context.Context) bool {
	if a.warp == nil || a.warp.binary == "" {
		a.warp = newWarpClient()
	}
	return warpActive(a.warp.status(ctx).State)
}

func (w *warpClient) command(ctx context.Context, args ...string) error {
	ctx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	_, err := w.run(ctx, args...)
	if ctx.Err() != nil {
		return fail(504, "WARP не ответил вовремя. Проверьте состояние и повторите действие.")
	}
	if err != nil {
		return fail(502, "WARP не выполнил действие. Откройте официальный клиент: проверьте службу и завершите первоначальную настройку.")
	}
	return nil
}

func (a *App) warpAPI(w http.ResponseWriter, r *http.Request) error {
	if runtime.GOOS != "windows" && runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		return fail(503, "WARP доступен в настольных сборках")
	}
	a.networkOp.Lock()
	defer a.networkOp.Unlock()
	if r.Method == "GET" && r.URL.Path == "/api/warp" {
		if a.warp == nil || a.warp.binary == "" {
			a.warp = newWarpClient()
		}
		writeJSON(w, 200, a.warpStatus(r.Context()))
		return nil
	}
	if r.Method != "POST" {
		return fail(405, "Действие WARP не поддерживается")
	}
	if a.warp == nil || a.warp.binary == "" {
		a.warp = newWarpClient()
	}
	if r.URL.Path == "/api/warp/install" {
		if time.Since(a.warpInstallerOpened) < 15*time.Second {
			return fail(409, "Установщик WARP уже открыт. Завершите установку в системном окне.")
		}
		ctx, cancel := context.WithTimeout(r.Context(), 35*time.Second)
		defer cancel()
		if err := installBundledWarp(ctx); err != nil {
			return fail(502, err.Error())
		}
		a.warpInstallerOpened = time.Now()
		writeJSON(w, 200, a.warpStatus(r.Context()))
		return nil
	}
	if a.warp == nil || a.warp.binary == "" {
		return fail(409, "Установите Cloudflare WARP и нажмите «Обновить состояние».")
	}
	s := a.warpStatus(r.Context())
	switch r.URL.Path {
	case "/api/warp/register":
		var in struct {
			Accepted bool `json:"accepted"`
		}
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&in) != nil || !in.Accepted {
			return fail(400, "Для регистрации подтвердите условия и политику Cloudflare.")
		}
		if s.State != "unregistered" {
			return fail(409, "Регистрация уже существует либо служба недоступна. Обновите состояние WARP.")
		}
		if err := a.warp.command(r.Context(), "--accept-tos", "registration", "new"); err != nil {
			return err
		}
	case "/api/warp/connect":
		if s.VPNRunning {
			return fail(409, "Сначала отключите VPN на вкладке «Подключение», затем включите WARP.")
		}
		if s.ZapretRunning {
			return fail(409, "Сначала остановите zapret, затем включите WARP.")
		}
		if s.State != "disconnected" {
			return fail(409, "Сначала завершите настройку WARP и дождитесь состояния «Отключён».")
		}
		a.cancelSpeed()
		if err := a.warp.command(r.Context(), "mode", "warp+doh"); err != nil {
			return err
		}
		if err := a.warp.command(r.Context(), "connect"); err != nil {
			return err
		}
	case "/api/warp/disconnect":
		a.cancelSpeed()
		if err := a.warp.command(r.Context(), "disconnect"); err != nil {
			return err
		}
	default:
		return fail(404, "Неизвестное действие WARP")
	}
	writeJSON(w, 200, a.warpStatus(r.Context()))
	return nil
}
