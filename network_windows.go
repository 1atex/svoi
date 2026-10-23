//go:build windows

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

func hideCommand(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
}
func protectChild(cmd *exec.Cmd) (func(), error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return nil, err
	}
	info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err = windows.SetInformationJobObject(job, 9, uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info))); err != nil {
		windows.CloseHandle(job)
		return nil, err
	}
	process, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(cmd.Process.Pid))
	if err != nil {
		windows.CloseHandle(job)
		return nil, err
	}
	defer windows.CloseHandle(process)
	if err = windows.AssignProcessToJobObject(job, process); err != nil {
		windows.CloseHandle(job)
		return nil, err
	}
	return func() { windows.CloseHandle(job) }, nil
}
func isElevated() bool {
	var token windows.Token
	if windows.OpenProcessToken(windows.CurrentProcess(), windows.TOKEN_QUERY, &token) != nil {
		return false
	}
	defer token.Close()
	return token.IsElevated()
}

const internetSettings = `Software\Microsoft\Windows\CurrentVersion\Internet Settings`

type savedRegValue struct {
	Exists bool   `json:"exists"`
	Type   uint32 `json:"type"`
	Text   string `json:"text"`
	Number uint64 `json:"number"`
}
type proxySnapshot struct {
	PID      int                      `json:"pid"`
	Expected string                   `json:"expected"`
	Values   map[string]savedRegValue `json:"values"`
}

func readProxyValue(key registry.Key, name string) (savedRegValue, error) {
	text, kind, err := key.GetStringValue(name)
	if err == nil {
		return savedRegValue{Exists: true, Type: kind, Text: text}, nil
	}
	if errors.Is(err, registry.ErrNotExist) {
		return savedRegValue{}, nil
	}
	number, kind, err := key.GetIntegerValue(name)
	if err != nil {
		return savedRegValue{}, err
	}
	return savedRegValue{Exists: true, Type: kind, Number: number}, nil
}
func notifyProxy() {
	proc := windows.NewLazySystemDLL("wininet.dll").NewProc("InternetSetOptionW")
	proc.Call(0, 39, 0, 0)
	proc.Call(0, 37, 0, 0)
}
func enableSystemProxy(dir string, port int) (func() error, error) {
	key, err := registry.OpenKey(registry.CURRENT_USER, internetSettings, registry.QUERY_VALUE|registry.SET_VALUE)
	if err != nil {
		return nil, err
	}
	defer key.Close()
	snapshot := proxySnapshot{PID: os.Getpid(), Expected: "127.0.0.1:" + strconv.Itoa(port), Values: map[string]savedRegValue{}}
	for _, name := range []string{"ProxyEnable", "ProxyServer", "ProxyOverride", "AutoConfigURL", "AutoDetect"} {
		v, err := readProxyValue(key, name)
		if err != nil {
			return nil, err
		}
		snapshot.Values[name] = v
	}
	data, _ := json.Marshal(snapshot)
	file := filepath.Join(dir, "proxy-recovery-"+secret()+".json")
	if err = os.WriteFile(file, data, 0600); err != nil {
		return nil, err
	}
	exe, err := os.Executable()
	if err != nil {
		os.Remove(file)
		return nil, err
	}
	watcher := exec.Command(exe, "-watch-parent", strconv.Itoa(os.Getpid()), "-watch-proxy", file)
	hideCommand(watcher)
	if err = watcher.Start(); err != nil {
		os.Remove(file)
		return nil, fmt.Errorf("не удалось запустить восстановление прокси: %w", err)
	}
	_ = watcher.Process.Release()
	if err = key.SetStringValue("ProxyServer", snapshot.Expected); err == nil {
		err = key.SetStringValue("ProxyOverride", "<local>;localhost;127.*;[::1]")
	}
	if err == nil {
		err = key.SetDWordValue("ProxyEnable", 1)
	}
	if err == nil {
		err = key.SetDWordValue("AutoDetect", 0)
	}
	if err == nil {
		err = key.DeleteValue("AutoConfigURL")
		if errors.Is(err, registry.ErrNotExist) {
			err = nil
		}
	}
	if err != nil {
		_ = restoreProxyFile(file)
		return nil, err
	}
	notifyProxy()
	return func() error { return restoreProxyFile(file) }, nil
}
func restoreProxyFile(file string) error {
	data, err := os.ReadFile(file)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var saved proxySnapshot
	if err = json.Unmarshal(data, &saved); err != nil {
		return err
	}
	key, err := registry.OpenKey(registry.CURRENT_USER, internetSettings, registry.QUERY_VALUE|registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer key.Close()
	current, _, _ := key.GetStringValue("ProxyServer")
	// Another app/user may have changed the proxy while SVOI was running.
	if current == saved.Expected {
		// Restore the ownership marker last so failed restores can be retried.
		for _, name := range []string{"AutoConfigURL", "AutoDetect", "ProxyOverride", "ProxyEnable", "ProxyServer"} {
			v := saved.Values[name]
			if !v.Exists {
				err = key.DeleteValue(name)
				if errors.Is(err, registry.ErrNotExist) {
					err = nil
				}
			} else {
				switch v.Type {
				case registry.DWORD:
					err = key.SetDWordValue(name, uint32(v.Number))
				case registry.QWORD:
					err = key.SetQWordValue(name, v.Number)
				case registry.SZ:
					err = key.SetStringValue(name, v.Text)
				case registry.EXPAND_SZ:
					err = key.SetExpandStringValue(name, v.Text)
				default:
					return fmt.Errorf("неподдерживаемый тип настройки %s", name)
				}
			}
			if err != nil {
				return err
			}
		}
		notifyProxy()
	}
	return os.Remove(file)
}
func recoverSystemProxy(dir string) error {
	files, _ := filepath.Glob(filepath.Join(dir, "proxy-recovery-*.json"))
	for _, file := range files {
		data, err := os.ReadFile(file)
		if err != nil {
			return err
		}
		var saved proxySnapshot
		if json.Unmarshal(data, &saved) != nil {
			continue
		}
		h, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(saved.PID))
		if err == nil {
			result, _ := windows.WaitForSingleObject(h, 0)
			windows.CloseHandle(h)
			if result == uint32(windows.WAIT_TIMEOUT) {
				continue
			}
		}
		if err = restoreProxyFile(file); err != nil {
			return err
		}
	}
	return nil
}
func watchProxy(parent int, file string) error {
	handle, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(parent))
	if err == nil {
		defer windows.CloseHandle(handle)
		for {
			result, err := windows.WaitForSingleObject(handle, 1500)
			if err != nil {
				return err
			}
			if result != uint32(windows.WAIT_TIMEOUT) {
				break
			}
			if _, err := os.Stat(file); errors.Is(err, os.ErrNotExist) {
				return nil
			}
		}
	}
	return restoreProxyFile(file)
}
