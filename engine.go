package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type EngineStatus struct {
	Available  bool       `json:"available"`
	Elevated   bool       `json:"elevated"`
	Problem    string     `json:"problem,omitempty"`
	Version    string     `json:"version"`
	State      string     `json:"state"`
	ServerID   string     `json:"serverId"`
	ServerName string     `json:"serverName"`
	Mode       string     `json:"mode"`
	SocksPort  int        `json:"socksPort"`
	HTTPPort   int        `json:"httpPort"`
	StartedAt  *time.Time `json:"startedAt,omitempty"`
	Error      string     `json:"error,omitempty"`
	Latency    int64      `json:"latency,omitempty"`
	Checked    bool       `json:"checked"`
	CheckedAt  *time.Time `json:"checkedAt,omitempty"`
	Routing    AppRouting `json:"routing"`
	Logs       []string   `json:"logs"`
}
type Engine struct {
	op           sync.Mutex
	mu           sync.Mutex
	binary       string
	dir          string
	status       EngineStatus
	cmd          *exec.Cmd
	done         chan struct{}
	configPath   string
	releaseJob   func()
	restoreProxy func() error
	redactions   []string
	checkURL     string
}

func newEngine(binary, dir string) (*Engine, error) {
	e := &Engine{binary: binary, dir: dir, status: EngineStatus{State: "stopped", Logs: []string{}}, checkURL: "https://www.gstatic.com/generate_204"}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	if err := recoverSystemProxy(dir); err != nil {
		e.status.Error = "Не удалось восстановить прежние настройки прокси: " + err.Error()
	}
	if _, err := os.Stat(binary); err != nil {
		e.status.Problem = "core_missing"
		e.status.Error = "Не найдено или недоступно ядро core/xray.exe. Установите SVOI через setup.exe или распакуйте весь Windows-архив: папка core должна находиться рядом с EXE. Затем перезапустите приложение."
		return e, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, "version")
	hideCommand(cmd)
	b, err := cmd.Output()
	if err != nil {
		e.status.Problem = "core_start_failed"
		e.status.Error = "Ядро Xray найдено, но не запускается. Распакуйте полный Windows x64 архив и проверьте, разрешён ли запуск core/xray.exe в Windows."
		return e, nil
	}
	e.status.Available = true
	e.status.Version = strings.SplitN(strings.TrimSpace(string(b)), "\n", 2)[0]
	return e, nil
}
func (e *Engine) Status() EngineStatus {
	return e.snapshot(true)
}

func (e *Engine) snapshot(includeLogs bool) EngineStatus {
	e.mu.Lock()
	defer e.mu.Unlock()
	s := e.status
	s.Elevated = isElevated()
	s.Routing.Processes = append([]string{}, e.status.Routing.Processes...)
	s.Logs = nil
	if includeLogs {
		s.Logs = append([]string{}, e.status.Logs...)
	}
	return s
}
func (e *Engine) Write(p []byte) (int, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, line := range strings.Split(strings.TrimSpace(string(p)), "\n") {
		if line == "" {
			continue
		}
		for _, secret := range e.redactions {
			line = strings.ReplaceAll(line, secret, "[скрыто]")
		}
		if len(line) > 800 {
			line = line[:800] + "…"
		}
		e.status.Logs = append(e.status.Logs, line)
	}
	if len(e.status.Logs) > 100 {
		e.status.Logs = e.status.Logs[len(e.status.Logs)-100:]
	}
	return len(p), nil
}
func (e *Engine) setError(err error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.status.State = "error"
	e.status.Error = err.Error()
}
func reservePort() (net.Listener, int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, 0, err
	}
	return l, l.Addr().(*net.TCPAddr).Port, nil
}
func credentialStrings(v any) []string {
	var all []string
	switch x := v.(type) {
	case map[string]any:
		for k, v := range x {
			switch strings.ToLower(k) {
			case "id", "password", "pass", "auth":
				if s, ok := v.(string); ok && len(s) > 3 {
					all = append(all, s)
				}
			}
			all = append(all, credentialStrings(v)...)
		}
	case []any:
		for _, v := range x {
			all = append(all, credentialStrings(v)...)
		}
	}
	return all
}
func (e *Engine) Start(server ServerConfig, mode string) error {
	return e.startContext(context.Background(), server, mode)
}
func (e *Engine) startContext(parent context.Context, server ServerConfig, mode string) error {
	e.op.Lock()
	defer e.op.Unlock()
	if err := parent.Err(); err != nil {
		return err
	}
	if mode != "local" && mode != "system" && mode != "tun" {
		return fail(400, "Неизвестный режим подключения")
	}
	if !e.Status().Available {
		return fail(503, "Ядро Xray не найдено. Распакуйте приложение вместе с папкой core.")
	}
	if mode == "tun" && !isElevated() {
		return fail(409, "Для TUN закройте SVOI и запустите его от имени администратора. Системный прокси работает без повышения прав.")
	}
	if err := e.stopLocked(); err != nil {
		return err
	}
	socks, sp, err := reservePort()
	if err != nil {
		return err
	}
	defer socks.Close()
	httpListener, hp, err := reservePort()
	if err != nil {
		return err
	}
	defer httpListener.Close()
	config, err := buildXrayConfig(server, sp, hp, mode)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(e.dir, "xray-*.json")
	if err != nil {
		return err
	}
	path := f.Name()
	defer func() {
		if e.configPath != path {
			_ = os.Remove(path)
		}
	}()
	if _, err = f.Write(config); err != nil {
		f.Close()
		return err
	}
	f.Close()
	var outbound any
	secretSource := server.Outbound
	if len(server.Profile) > 0 {
		secretSource = server.Profile
	}
	_ = json.Unmarshal(secretSource, &outbound)
	e.mu.Lock()
	e.status.State = "starting"
	e.status.Error = ""
	e.status.Checked = false
	e.status.CheckedAt = nil
	e.status.Latency = 0
	e.status.Logs = []string{}
	e.redactions = credentialStrings(outbound)
	e.mu.Unlock()
	ctx, cancel := context.WithTimeout(parent, 10*time.Second)
	defer cancel()
	validate := exec.CommandContext(ctx, e.binary, "run", "-test", "-c", path)
	hideCommand(validate)
	validate.Dir = filepath.Dir(e.binary)
	validate.Stdout = e
	validate.Stderr = e
	if err = validate.Run(); err != nil {
		err = fail(422, "Xray отклонил конфигурацию. Подробности — в журнале ядра.")
		e.setError(err)
		return err
	}
	cmd := exec.Command(e.binary, "run", "-c", path)
	hideCommand(cmd)
	cmd.Dir = filepath.Dir(e.binary)
	cmd.Stdout = e
	cmd.Stderr = e
	socks.Close()
	httpListener.Close()
	if err = cmd.Start(); err != nil {
		e.setError(err)
		return err
	}
	release, err := protectChild(cmd)
	if err != nil {
		cmd.Process.Kill()
		cmd.Wait()
		e.setError(err)
		return err
	}
	e.cmd = cmd
	e.done = make(chan struct{})
	e.configPath = path
	e.releaseJob = release
	done := e.done
	go func() {
		err := cmd.Wait()
		e.mu.Lock()
		if e.cmd == cmd && e.status.State != "stopping" && e.status.State != "stopped" {
			e.status.State = "error"
			if err != nil {
				e.status.Error = "Процесс Xray завершился: " + err.Error()
			} else {
				e.status.Error = "Процесс Xray завершился"
			}
		}
		e.mu.Unlock()
		close(done)
	}()
	ready := false
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case <-parent.Done():
			e.stopLocked()
			return parent.Err()
		case <-done:
			err = fail(502, "Xray завершился при запуске. Проверьте журнал.")
			e.stopLocked()
			e.setError(err)
			return err
		default:
		}
		c, dialErr := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(hp)), 150*time.Millisecond)
		if dialErr == nil {
			c.Close()
			ready = true
			break
		}
		time.Sleep(60 * time.Millisecond)
	}
	if !ready {
		err = fail(504, "Xray не открыл локальный порт за 8 секунд")
		e.stopLocked()
		e.setError(err)
		return err
	}
	if mode == "system" {
		restore, proxyErr := enableSystemProxy(e.dir, hp)
		if proxyErr != nil {
			e.stopLocked()
			e.setError(proxyErr)
			return proxyErr
		}
		e.restoreProxy = restore
	}
	now := time.Now().UTC()
	e.mu.Lock()
	e.status.State = "running"
	e.status.ServerID = server.ID
	e.status.ServerName = server.Name
	e.status.Mode = mode
	e.status.Routing = AppRouting{Mode: "all", Processes: []string{}}
	if mode == "tun" && server.RuntimeApps != nil {
		e.status.Routing = AppRouting{Mode: server.RuntimeApps.Mode, Processes: append([]string{}, server.RuntimeApps.Processes...)}
	}
	e.status.SocksPort = sp
	e.status.HTTPPort = hp
	e.status.StartedAt = &now
	e.mu.Unlock()

	go func() {
		<-done
		e.op.Lock()
		defer e.op.Unlock()
		if e.cmd == cmd {
			problem := e.Status().Error
			_ = e.stopLocked()
			if problem != "" {
				e.setError(errors.New(problem))
			}
		}
	}()
	return nil
}
func (e *Engine) Stop() error { e.op.Lock(); defer e.op.Unlock(); return e.stopLocked() }
func (e *Engine) stopLocked() error {
	var restoreErr error
	if e.restoreProxy != nil {
		restoreErr = e.restoreProxy()
		if restoreErr == nil {
			e.restoreProxy = nil
		}
	}
	if e.cmd != nil {
		e.mu.Lock()
		e.status.State = "stopping"
		e.mu.Unlock()
		_ = e.cmd.Process.Kill()
		<-e.done
		if e.releaseJob != nil {
			e.releaseJob()
			e.releaseJob = nil
		}
		e.mu.Lock()
		e.cmd = nil
		e.mu.Unlock()
	}
	if e.configPath != "" {
		_ = os.Remove(e.configPath)
		e.configPath = ""
	}
	e.mu.Lock()
	e.status.State = "stopped"
	e.status.Checked = false
	e.status.CheckedAt = nil
	e.status.SocksPort = 0
	e.status.Latency = 0
	e.status.HTTPPort = 0
	e.status.StartedAt = nil
	e.status.Error = ""
	if restoreErr != nil {
		e.status.Error = "Не удалось восстановить системный прокси: " + restoreErr.Error()
		e.status.State = "error"
	}
	e.mu.Unlock()
	return restoreErr
}
func (e *Engine) Check(ctx context.Context) (int64, error) {
	e.op.Lock()
	defer e.op.Unlock()
	s := e.Status()
	if s.State != "running" {
		return 0, fail(409, "Сначала подключитесь к серверу")
	}
	proxyURL, _ := url.Parse("http://127.0.0.1:" + strconv.Itoa(s.HTTPPort))
	transport := &http.Transport{Proxy: http.ProxyURL(proxyURL), TLSHandshakeTimeout: 8 * time.Second}
	if s.Mode == "tun" {

		transport.Proxy = nil
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 12 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	req, _ := http.NewRequestWithContext(ctx, "GET", e.checkURL, nil)
	start := time.Now()
	resp, err := client.Do(req)
	if err == nil {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		resp.Body.Close()
		if resp.StatusCode < 200 || resp.StatusCode >= 400 {
			err = fmt.Errorf("HTTP %d", resp.StatusCode)
		}
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	checkedAt := time.Now().UTC()
	e.status.CheckedAt = &checkedAt
	if err != nil {
		e.status.Checked = false
		e.status.Latency = 0
		e.status.Error = "Проверка соединения не прошла: " + err.Error()
		return 0, fail(502, e.status.Error)
	}
	e.status.Latency = time.Since(start).Milliseconds()
	e.status.Checked = true
	e.status.Error = ""
	return e.status.Latency, nil
}

func (a *App) engineAPI(w http.ResponseWriter, r *http.Request) error {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	ip := net.ParseIP(host)
	if a.engine == nil || ip == nil || !ip.IsLoopback() {
		return fail(403, "Управление Xray доступно только в локальном приложении")
	}
	a.mu.Lock()
	g, _, err := a.auth(r)
	if err != nil {
		a.mu.Unlock()
		return err
	}
	var servers []ServerConfig

	if r.Method == "POST" && r.URL.Path == "/api/connection/start" {
		servers = append([]ServerConfig{}, g.Servers...)
	}
	a.mu.Unlock()
	switch {
	case r.Method == "GET" && r.URL.Path == "/api/connection":
		status := a.engine.snapshot(r.URL.Query().Get("logs") == "1")
		writeJSON(w, 200, status)
		return nil
	case r.Method == "POST" && r.URL.Path == "/api/connection/start":
		var in struct {
			ServerID string `json:"serverId"`
			Mode     string `json:"mode"`
		}
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&in) != nil {
			return fail(400, "Некорректный запрос подключения")
		}
		for _, server := range servers {
			if server.ID == in.ServerID {
				if a.zapret != nil && a.zapret.blocksVPN(in.Mode) {
					return fail(409, "Дождитесь окончания перебора стратегий; перед TUN остановите zapret")
				}
				settings := a.localSettings()
				server.RuntimeApps = &settings.Routing
				if err = a.engine.Start(server, in.Mode); err != nil {
					return err
				}
				writeJSON(w, 200, a.engine.Status())
				return nil
			}
		}
		return fail(404, "Сервер не найден. Обновите подписку.")
	case r.Method == "POST" && r.URL.Path == "/api/connection/stop":
		if err = a.engine.Stop(); err != nil {
			return err
		}
		writeJSON(w, 200, a.engine.Status())
		return nil
	case r.Method == "POST" && r.URL.Path == "/api/connection/check":
		if _, err = a.engine.Check(r.Context()); err != nil {
			return err
		}
		writeJSON(w, 200, a.engine.Status())
		return nil
	}
	return fail(404, "Метод подключения не найден")
}
