package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"time"
)

func hideCommand(cmd *exec.Cmd)              { cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} }
func protectChild(*exec.Cmd) (func(), error) { return func() {}, nil }
func isElevated() bool                       { return os.Geteuid() == 0 }
func canCreateTun(string) bool               { return false }
func watchProxy(int, string) error           { return nil }

func macProxyHelper() string {
	exe, _ := os.Executable()
	return filepath.Join(filepath.Dir(exe), "svoi-proxy")
}

func recoverSystemProxy(dir string) error {
	if _, err := os.Stat(filepath.Join(dir, "macos-proxy.plist")); os.IsNotExist(err) {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, macProxyHelper(), "recover", dir)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("откройте SVOI и разрешите восстановление настроек сети: %s", output)
	}
	return nil
}

func enableSystemProxy(dir string, port int) (func() error, error) {
	cmd := exec.Command(macProxyHelper(), "session", dir, strconv.Itoa(port))
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		in.Close()
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		in.Close()
		return nil, fmt.Errorf("не удалось запустить помощник прокси. Переустановите SVOI.app: %w", err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	ready := make(chan error, 1)
	go func() {
		var response struct {
			Ready bool   `json:"ready"`
			Error string `json:"error"`
		}
		err := json.NewDecoder(bufio.NewReader(out)).Decode(&response)
		if err == nil && !response.Ready {
			err = fmt.Errorf("%s", response.Error)
		}
		ready <- err
	}()
	select {
	case err = <-ready:
	case <-time.After(90 * time.Second):
		err = fmt.Errorf("истекло время ожидания разрешения macOS")
	}
	if err != nil {
		in.Close()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			cmd.Process.Kill()
			<-done
		}
		return nil, fmt.Errorf("системный прокси не включён: %w. Разрешите изменение сети или выберите ручной прокси", err)
	}
	var once sync.Once
	var stopped error
	return func() error {
		once.Do(func() {
			in.Close()
			select {
			case stopped = <-done:
			case <-time.After(30 * time.Second):
				stopped = fmt.Errorf("macOS ещё восстанавливает прокси. Дождитесь запроса системы или перезапустите SVOI")
			}
		})
		return stopped
	}, nil
}
