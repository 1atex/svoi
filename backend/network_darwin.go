package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"time"
)

func hideCommand(cmd *exec.Cmd) { cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} }
func protectChild(child *exec.Cmd) (func(), error) {
	watcher := exec.Command(macProxyHelper(), "watch", strconv.Itoa(child.Process.Pid))
	input, err := watcher.StdinPipe()
	if err != nil {
		return nil, err
	}
	if err = watcher.Start(); err != nil {
		input.Close()
		return nil, err
	}
	done := make(chan struct{})
	go func() { _ = watcher.Wait(); close(done) }()
	var once sync.Once
	return func() {
		once.Do(func() {
			_, _ = input.Write([]byte("release\n"))
			_ = input.Close()
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				_ = watcher.Process.Kill()
			}
		})
	}, nil
}
func isElevated() bool             { return os.Geteuid() == 0 }
func canCreateTun(string) bool     { return false }
func watchProxy(int, string) error { return nil }

var macProxyHelper = defaultMacProxyHelper

func defaultMacProxyHelper() string {
	exe, _ := os.Executable()
	return filepath.Join(filepath.Dir(exe), "svoi-proxy")
}

func recoverSystemProxy(dir string) error {
	if _, err := os.Stat(filepath.Join(dir, "macos-proxy.plist")); os.IsNotExist(err) {
		return nil
	}
	if _, err := macProxyRuntime.call(macProxyRequest{Operation: "recover", Directory: dir}); err != nil {
		return fmt.Errorf("откройте SVOI и разрешите восстановление настроек сети: %w", err)
	}
	return nil
}

type macProxyRequest struct {
	Operation string `json:"operation"`
	Directory string `json:"directory,omitempty"`
	Port      int    `json:"port,omitempty"`
}

type macProxyResponse struct {
	Ready                 bool   `json:"ready"`
	Error                 string `json:"error"`
	PID                   int    `json:"pid"`
	AuthorizationRequests int    `json:"authorizationRequests"`
}

type macProxyProcess struct {
	cmd     *exec.Cmd
	input   io.WriteCloser
	decoder *json.Decoder
	done    chan struct{}
}

type macProxyBroker struct {
	mu      sync.Mutex
	process *macProxyProcess
}

var macProxyRuntime macProxyBroker

func (b *macProxyBroker) start() error {
	if b.process != nil {
		select {
		case <-b.process.done:
			_ = b.process.input.Close()
			b.process = nil
		default:
			return nil
		}
	}
	cmd := exec.Command(macProxyHelper(), "broker")
	input, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		_ = input.Close()
		return err
	}
	if err := cmd.Start(); err != nil {
		_ = input.Close()
		return fmt.Errorf("не удалось запустить помощник прокси. Переустановите SVOI.app: %w", err)
	}
	p := &macProxyProcess{cmd: cmd, input: input, decoder: json.NewDecoder(bufio.NewReader(out)), done: make(chan struct{})}
	b.process = p
	go func() { _ = cmd.Wait(); close(p.done) }()
	return nil
}

func (b *macProxyBroker) closeLocked() {
	p := b.process
	if p == nil {
		return
	}
	b.process = nil
	_ = p.input.Close()
	select {
	case <-p.done:
	case <-time.After(5 * time.Second):
		_ = p.cmd.Process.Kill()
		<-p.done
	}
}

func (b *macProxyBroker) call(request macProxyRequest) (macProxyResponse, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	var response macProxyResponse
	if err := b.start(); err != nil {
		return response, err
	}
	p := b.process
	if err := json.NewEncoder(p.input).Encode(request); err != nil {
		b.closeLocked()
		return response, fmt.Errorf("связь с помощником прокси прервана: %w", err)
	}
	ready := make(chan error, 1)
	go func() {
		ready <- p.decoder.Decode(&response)
	}()
	var err error
	timer := time.NewTimer(90 * time.Second)
	defer timer.Stop()
	select {
	case err = <-ready:
	case <-timer.C:
		err = fmt.Errorf("истекло время ожидания разрешения macOS")
	}
	if err != nil {
		b.closeLocked()
		return macProxyResponse{}, err
	}
	if !response.Ready {
		return response, fmt.Errorf("%s", response.Error)
	}
	return response, nil
}

func enableSystemProxy(dir string, port int) (func() error, error) {
	if _, err := macProxyRuntime.call(macProxyRequest{Operation: "start", Directory: dir, Port: port}); err != nil {
		return nil, fmt.Errorf("системный прокси не включён: %w. Разрешите изменение сети или выберите ручной прокси", err)
	}
	var mu sync.Mutex
	stopped := false
	return func() error {
		mu.Lock()
		defer mu.Unlock()
		if stopped {
			return nil
		}
		if _, err := macProxyRuntime.call(macProxyRequest{Operation: "stop", Directory: dir}); err != nil {
			return fmt.Errorf("macOS не восстановила прокси. Повторите отключение или отключите прокси в настройках Wi-Fi/Ethernet: %w", err)
		}
		stopped = true
		return nil
	}, nil
}
