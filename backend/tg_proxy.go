package main

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type tgProxyConfig struct {
	Port   int    `json:"port"`
	Secret string `json:"secret"`
}

type tgProxy struct {
	op                sync.Mutex
	mu                sync.Mutex
	config            tgProxyConfig
	path, binary      string
	cmd               *exec.Cmd
	input             io.WriteCloser
	done              chan struct{}
	running, stopping bool
	lastError         string
	logs              []string
}

func newTGProxy(binary, path string) *tgProxy {
	p := &tgProxy{binary: binary, path: path, config: tgProxyConfig{Port: 1443}}
	b, err := os.ReadFile(path)
	if err == nil {
		err = json.Unmarshal(b, &p.config)
		if err == nil {
			err = validateTGProxyConfig(p.config)
		}
	}
	if err != nil && !os.IsNotExist(err) {
		p.lastError = "Не удалось прочитать настройки Telegram-прокси: " + err.Error()
		return p
	}
	if os.IsNotExist(err) {
		secret := make([]byte, 16)
		if _, err = rand.Read(secret); err == nil {
			p.config.Secret = hex.EncodeToString(secret)
			err = p.save(p.config)
		}
		if err != nil {
			p.lastError = "Не удалось сохранить настройки Telegram-прокси: " + err.Error()
		}
	}
	return p
}

func validateTGProxyConfig(c tgProxyConfig) error {
	if c.Port < 1024 || c.Port > 65535 {
		return fmt.Errorf("укажите порт от 1024 до 65535")
	}
	b, err := hex.DecodeString(c.Secret)
	if err != nil || len(b) != 16 || c.Secret != strings.ToLower(c.Secret) {
		return fmt.Errorf("повреждён ключ локального прокси")
	}
	return nil
}

func (p *tgProxy) save(c tgProxyConfig) error {
	if err := validateTGProxyConfig(c); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p.path), 0700); err != nil {
		return err
	}
	b, err := json.Marshal(c)
	if err != nil {
		return err
	}
	return os.WriteFile(p.path, b, 0600)
}

func (p *tgProxy) status() map[string]any {
	p.mu.Lock()
	defer p.mu.Unlock()
	_, err := os.Stat(p.binary)
	link := ""
	if p.running {
		link = fmt.Sprintf("tg://proxy?server=127.0.0.1&port=%d&secret=dd%s", p.config.Port, p.config.Secret)
	}
	return map[string]any{"installed": err == nil, "version": "1.11.2", "running": p.running,
		"port": p.config.Port, "link": link, "error": p.lastError, "logs": append([]string{}, p.logs...)}
}

func (p *tgProxy) record(line string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	line = strings.ReplaceAll(line, p.config.Secret, "[скрыто]")
	if len(line) > 2048 {
		line = line[:2048]
	}
	p.logs = append(p.logs, line)
	if len(p.logs) > 80 {
		p.logs = p.logs[len(p.logs)-80:]
	}
}

func (p *tgProxy) Start() error {
	p.op.Lock()
	defer p.op.Unlock()
	p.mu.Lock()
	if p.cmd != nil {
		p.mu.Unlock()
		return nil
	}
	if err := validateTGProxyConfig(p.config); err != nil {
		p.mu.Unlock()
		return err
	}
	p.mu.Unlock()
	if _, err := os.Stat(p.binary); err != nil {
		return fmt.Errorf("Telegram-прокси не установлен. Переустановите полную сборку SVOI")
	}
	cmd := exec.Command(p.binary, "--config", p.path)
	hideCommand(cmd)
	input, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	reader, writer, err := os.Pipe()
	if err != nil {
		input.Close()
		return err
	}
	cmd.Stdout, cmd.Stderr = writer, writer
	if err = cmd.Start(); err != nil {
		input.Close()
		reader.Close()
		writer.Close()
		return err
	}
	writer.Close()
	release, err := protectChild(cmd)
	if err != nil {
		cmd.Process.Kill()
		cmd.Wait()
		input.Close()
		reader.Close()
		return fmt.Errorf("не удалось привязать Telegram-прокси к SVOI: %w", err)
	}
	done, ready := make(chan struct{}), make(chan struct{})
	p.mu.Lock()
	p.cmd, p.input, p.done = cmd, input, done
	p.running, p.stopping, p.lastError = false, false, ""
	p.logs = nil
	p.mu.Unlock()
	readDone := make(chan struct{})
	go func() {
		defer close(readDone)
		defer reader.Close()
		s := bufio.NewScanner(reader)
		s.Buffer(make([]byte, 4096), 65536)
		var once sync.Once
		for s.Scan() {
			line := strings.TrimSpace(s.Text())
			if line == "SVOI_TG_READY" {
				once.Do(func() { close(ready) })
				continue
			}
			p.record(line)
		}
	}()
	go func() {
		err := cmd.Wait()
		input.Close()
		release()
		<-readDone
		p.mu.Lock()
		if !p.stopping {
			p.lastError = "Telegram-прокси завершился. Попробуйте запустить снова; подробности — в журнале."
			if err != nil {
				p.lastError += " " + err.Error()
			}
		}
		p.cmd, p.input, p.running = nil, nil, false
		p.mu.Unlock()
		close(done)
	}()
	timer := time.NewTimer(15 * time.Second)
	defer timer.Stop()
	select {
	case <-ready:
		p.mu.Lock()
		defer p.mu.Unlock()
		if p.cmd == nil {
			return fmt.Errorf("%s", p.lastError)
		}
		p.running = true
		return nil
	case <-done:
		return fmt.Errorf("не удалось запустить Telegram-прокси. Если порт занят, измените его; подробности — в журнале")
	case <-timer.C:
		p.stopLocked()
		return fmt.Errorf("Telegram-прокси не успел запуститься. Попробуйте ещё раз или откройте журнал")
	}
}

func (p *tgProxy) stopLocked() error {
	p.mu.Lock()
	cmd, input, done := p.cmd, p.input, p.done
	p.stopping = true
	p.mu.Unlock()
	if cmd == nil {
		return nil
	}
	input.Close()
	select {
	case <-done:
		return nil
	case <-time.After(5 * time.Second):
		if err := cmd.Process.Kill(); err != nil && err != os.ErrProcessDone {
			return err
		}
	}
	select {
	case <-done:
		return nil
	case <-time.After(3 * time.Second):
		return fmt.Errorf("Telegram-прокси ещё завершается. Повторите через несколько секунд")
	}
}

func (p *tgProxy) Stop() error {
	p.op.Lock()
	defer p.op.Unlock()
	return p.stopLocked()
}

func (p *tgProxy) API(w http.ResponseWriter, r *http.Request) error {
	switch {
	case r.Method == "GET" && r.URL.Path == "/api/tg-proxy":
	case r.Method == "POST" && r.URL.Path == "/api/tg-proxy/start":
		if err := p.Start(); err != nil {
			return fail(409, err.Error())
		}
	case r.Method == "POST" && r.URL.Path == "/api/tg-proxy/stop":
		if err := p.Stop(); err != nil {
			return fail(409, err.Error())
		}
	case r.Method == "POST" && r.URL.Path == "/api/tg-proxy/config":
		var v struct {
			Port int `json:"port"`
		}
		dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024))
		dec.DisallowUnknownFields()
		if dec.Decode(&v) != nil {
			return fail(400, "Некорректный порт")
		}
		p.op.Lock()
		defer p.op.Unlock()
		p.mu.Lock()
		defer p.mu.Unlock()
		if p.cmd != nil {
			return fail(409, "Сначала остановите Telegram-прокси")
		}
		c := p.config
		c.Port = v.Port
		if err := p.save(c); err != nil {
			return fail(400, err.Error())
		}
		p.config, p.lastError = c, ""
		writeJSON(w, 200, map[string]bool{"saved": true})
		return nil
	default:
		return fail(404, "Действие Telegram-прокси не найдено")
	}
	writeJSON(w, 200, p.status())
	return nil
}
