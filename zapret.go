package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

type Zapret struct {
	app       *App
	root      string
	client    *http.Client
	installed zapretInstall
	job       ZapretJob
	cancel    context.CancelFunc
	jobDone   chan struct{}

	op        sync.Mutex
	mu        sync.Mutex
	cmd       *exec.Cmd
	done      chan struct{}
	release   func()
	logs      []string
	strategy  string
	lastError string
	engine    *Engine
}

func (z *Zapret) Write(p []byte) (int, error) {
	z.mu.Lock()
	defer z.mu.Unlock()
	for _, s := range strings.Split(strings.TrimSpace(string(p)), "\n") {
		if len(s) > 800 {
			s = s[:800]
		}
		if s != "" {
			z.logs = append(z.logs, s)
		}
	}
	if len(z.logs) > 80 {
		z.logs = z.logs[len(z.logs)-80:]
	}
	return len(p), nil
}
func zapretStrategies(folder string) []string {
	names := []string{}
	if folder == "" {
		return names
	}
	entries, _ := os.ReadDir(folder)
	for _, e := range entries {
		n := e.Name()
		if !e.IsDir() && strings.HasPrefix(strings.ToLower(n), "general") && strings.HasSuffix(strings.ToLower(n), ".bat") {
			names = append(names, n)
		}
	}
	sort.Strings(names)
	return names
}
func (z *Zapret) running() bool { z.mu.Lock(); defer z.mu.Unlock(); return z.cmd != nil }
func (z *Zapret) status(folder string) map[string]any {
	return z.snapshot(folder, false)
}

func (z *Zapret) snapshot(folder string, summary bool) map[string]any {
	z.mu.Lock()
	folder = z.effectiveFolderLocked(folder)
	job := z.job
	results := z.job.Results
	if summary && len(results) > 400 {
		results = results[len(results)-400:]
	}
	job.Results = append([]CheckResult{}, results...)
	status := map[string]any{"running": z.cmd != nil, "strategy": z.strategy, "error": z.lastError, "logs": append([]string{}, z.logs...), "folder": folder, "managed": folder != "" && folder == z.managedFolderLocked(), "version": z.installed.Version, "pendingVersion": z.installed.PendingVersion, "job": job}
	z.mu.Unlock()

	status["strategies"] = zapretStrategies(folder)
	status["elevated"] = isElevated()
	return status
}

func parseZapretStrategy(folder, name string) ([]string, error) {
	if filepath.Base(name) != name || !strings.HasPrefix(strings.ToLower(name), "general") || !strings.HasSuffix(strings.ToLower(name), ".bat") {
		return nil, fmt.Errorf("Неизвестная стратегия")
	}
	path := filepath.Join(folder, name)
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(b) > 128<<10 {
		return nil, fmt.Errorf("Слишком большой файл стратегии")
	}
	text := strings.ReplaceAll(string(b), "\r\n", "\n")
	text = strings.ReplaceAll(text, "^\n", "")
	line := ""
	for _, s := range strings.Split(text, "\n") {
		idx := strings.Index(strings.ToLower(s), "winws.exe\"")
		if idx >= 0 {
			if line != "" {
				return nil, fmt.Errorf("Стратегия содержит несколько запусков winws")
			}
			line = strings.TrimSpace(s[idx+len("winws.exe\""):])
		}
	}
	if line == "" {
		return nil, fmt.Errorf("Не найдена команда winws.exe")
	}
	replacements := map[string]string{"%BIN%": filepath.Join(folder, "bin") + string(os.PathSeparator), "%LISTS%": filepath.Join(folder, "lists") + string(os.PathSeparator), "%GameFilter%": "0", "%GameFilterTCP%": "0", "%GameFilterUDP%": "0"}
	for k, v := range replacements {
		line = strings.ReplaceAll(line, k, v)
	}
	if strings.ContainsAny(line, "%\r\n\x00") {
		return nil, fmt.Errorf("Стратегия использует неподдерживаемые переменные")
	}
	args := []string{}
	var token strings.Builder
	quoted := false
	for _, c := range line {
		if c == '"' {
			quoted = !quoted
			continue
		}
		if (c == ' ' || c == '\t') && !quoted {
			if token.Len() > 0 {
				args = append(args, token.String())
				token.Reset()
			}
		} else {
			token.WriteRune(c)
		}
	}
	if quoted {
		return nil, fmt.Errorf("Незакрытая кавычка в стратегии")
	}
	if token.Len() > 0 {
		args = append(args, token.String())
	}
	if len(args) == 0 {
		return nil, fmt.Errorf("Пустая стратегия")
	}
	for _, arg := range args {
		if !strings.HasPrefix(arg, "--") {
			return nil, fmt.Errorf("Неподдерживаемая команда в стратегии")
		}
	}
	return args, nil
}
func (z *Zapret) Start(folder, name string) error { return z.start(folder, name, false) }
func (z *Zapret) start(folder, name string, internal bool) error {
	z.op.Lock()
	defer z.op.Unlock()
	z.mu.Lock()
	busy := z.job.Busy
	z.mu.Unlock()
	if busy && !internal {
		return fail(409, "Дождитесь завершения проверки или обновления")
	}
	if z.running() {
		return fail(409, "Сначала остановите текущую стратегию")
	}
	if !isElevated() {
		return fail(409, "Для zapret запустите SVOI от имени администратора")
	}
	if s := z.engine.Status(); s.State == "running" && s.Mode == "tun" {
		return fail(409, "Сначала отключите TUN: совместная работа с zapret пока не поддерживается")
	}
	if externalZapretRunning() {
		return fail(409, "Уже работает другой winws. Остановите его через прежний лаунчер или службу")
	}
	args, err := parseZapretStrategy(folder, name)
	if err != nil {
		return err
	}
	binary := filepath.Join(folder, "bin", "winws.exe")
	if _, err = os.Stat(binary); err != nil {
		return fail(400, "В выбранной папке нет bin/winws.exe")
	}

	for _, n := range []string{"list-general-user.txt", "list-exclude-user.txt", "ipset-exclude-user.txt"} {
		p := filepath.Join(folder, "lists", n)
		f, e := os.OpenFile(p, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if e == nil {
			placeholder := "domain.example.abc\n"
			if n == "ipset-exclude-user.txt" {
				placeholder = "203.0.113.113/32\n"
			}
			f.WriteString(placeholder)
			f.Close()
		} else if !os.IsExist(e) {
			return e
		}
	}
	cmd := exec.Command(binary, args...)
	cmd.Dir = filepath.Join(folder, "bin")
	hideCommand(cmd)
	cmd.Stdout = z
	cmd.Stderr = z
	z.mu.Lock()
	z.logs = []string{}
	z.lastError = ""
	z.mu.Unlock()
	if err = cmd.Start(); err != nil {
		return err
	}
	release, err := protectChild(cmd)
	if err != nil {
		cmd.Process.Kill()
		cmd.Wait()
		return err
	}
	done := make(chan struct{})
	z.mu.Lock()
	z.cmd = cmd
	z.done = done
	z.release = release
	z.strategy = name
	z.mu.Unlock()
	go func() {
		err := cmd.Wait()
		z.mu.Lock()
		if z.cmd == cmd {
			z.cmd = nil
			if err != nil {
				z.lastError = "winws завершился: " + err.Error()
			}
		}
		z.mu.Unlock()
		release()
		close(done)
	}()
	return nil
}
func (z *Zapret) stopProcess() {
	z.op.Lock()
	defer z.op.Unlock()
	z.mu.Lock()
	cmd, done := z.cmd, z.done
	z.cmd = nil
	z.mu.Unlock()
	if cmd != nil {
		cmd.Process.Kill()
		<-done
	}
}
func (z *Zapret) Stop() {
	z.mu.Lock()
	cancel, done := z.cancel, z.jobDone
	z.mu.Unlock()
	if cancel != nil {
		cancel()
		if done != nil {
			<-done
		}
	}
	z.stopProcess()
	z.op.Lock()
	defer z.op.Unlock()
	z.activatePending()
}
func (z *Zapret) API(w http.ResponseWriter, r *http.Request, folder string) error {
	z.mu.Lock()
	folder = z.effectiveFolderLocked(folder)
	z.mu.Unlock()
	switch {
	case r.Method == "GET" && r.URL.Path == "/api/zapret":
	case r.Method == "POST" && r.URL.Path == "/api/zapret/start":
		var in struct {
			Strategy string `json:"strategy"`
		}
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&in) != nil {
			return fail(400, "Некорректный запрос")
		}
		if err := z.Start(folder, in.Strategy); err != nil {
			return err
		}
	case r.Method == "POST" && r.URL.Path == "/api/zapret/stop":
		z.mu.Lock()
		busy := z.job.Busy
		z.mu.Unlock()
		if busy {
			return fail(409, "Сначала остановите текущую задачу")
		}
		z.Stop()
	case r.Method == "POST" && r.URL.Path == "/api/zapret/cancel":
		z.mu.Lock()
		if z.cancel != nil {
			z.cancel()
		}
		z.mu.Unlock()
	case r.Method == "POST" && r.URL.Path == "/api/zapret/job":
		var input struct {
			Kind       string   `json:"kind"`
			Strategies []string `json:"strategies"`
			Sweep      bool     `json:"sweep"`
		}
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&input) != nil {
			return fail(400, "Некорректная задача")
		}
		if err := z.launchJob(input.Kind, input.Strategies, input.Sweep); err != nil {
			return err
		}
	default:
		return fail(404, "Метод zapret не найден")
	}
	writeJSON(w, 200, z.snapshot(folder, r.URL.Query().Get("summary") == "1"))
	return nil
}
