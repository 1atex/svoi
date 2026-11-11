package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/Microsoft/go-winio"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

func init() {
	startIslandTransport = startWindowsIsland
	sealIslandGrant = func(b []byte) ([]byte, error) { return islandCrypt(b, true) }
	openIslandGrant = func(b []byte) ([]byte, error) { return islandCrypt(b, false) }
}

func islandCrypt(b []byte, seal bool) ([]byte, error) {
	if len(b) == 0 {
		return nil, fmt.Errorf("empty permission")
	}
	in := windows.DataBlob{Size: uint32(len(b)), Data: &b[0]}
	var out windows.DataBlob
	var err error
	if seal {
		err = windows.CryptProtectData(&in, nil, nil, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &out)
	} else {
		err = windows.CryptUnprotectData(&in, nil, nil, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &out)
	}
	if err != nil {
		return nil, err
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data)))
	return append([]byte{}, unsafe.Slice(out.Data, out.Size)...), nil
}

func islandUser(process windows.Handle) (string, error) {
	var token windows.Token
	if err := windows.OpenProcessToken(process, windows.TOKEN_QUERY, &token); err != nil {
		return "", err
	}
	defer token.Close()
	u, err := token.GetTokenUser()
	if err != nil {
		return "", err
	}
	return u.User.Sid.String(), nil
}

func startWindowsIsland(a *App) (func(), error) {
	user, err := islandUser(windows.CurrentProcess())
	if err != nil {
		return nil, err
	}
	listener, err := winio.ListenPipe(`\\.\pipe\SVOI.NightIsland.v1.`+user, &winio.PipeConfig{SecurityDescriptor: "D:P(A;;GA;;;" + user + ")", InputBufferSize: 4096, OutputBufferSize: 65536})
	if err != nil {
		return nil, err
	}
	if key, _, err := registry.CreateKey(registry.CURRENT_USER, `Software\SVOI\NightIsland`, registry.SET_VALUE); err == nil {
		_ = key.SetStringValue("Application", desktopExecutable)
		key.Close()
	}
	ctx, cancel := context.WithCancel(context.Background())
	var clients sync.Map
	b := a.island()
	b.mu.Lock()
	b.closeClients = func() { clients.Range(func(key, value any) bool { value.(func())(); return true }) }
	b.mu.Unlock()
	slots := make(chan struct{}, 4)
	cache := map[string]islandPeer{}
	var cacheMu sync.Mutex
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			select {
			case slots <- struct{}{}:
			default:
				connection.Close()
				continue
			}
			clients.Store(connection, func() { connection.Close() })
			go func(c net.Conn) {
				defer func() { clients.Delete(c); c.Close(); <-slots }()
				_ = c.SetDeadline(time.Now().Add(45 * time.Second))
				fd, ok := c.(interface{ Fd() uintptr })
				if !ok {
					return
				}
				var pid uint32
				proc := windows.NewLazySystemDLL("kernel32.dll").NewProc("GetNamedPipeClientProcessId")
				result, _, _ := proc.Call(fd.Fd(), uintptr(unsafe.Pointer(&pid)))
				if result == 0 {
					return
				}
				process, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
				if err != nil {
					return
				}
				defer windows.CloseHandle(process)
				owner, err := islandUser(process)
				if err != nil || owner != user {
					return
				}
				var name [32768]uint16
				size := uint32(len(name))
				if windows.QueryFullProcessImageName(process, 0, &name[0], &size) != nil {
					return
				}
				path := strings.ToLower(filepath.Clean(windows.UTF16ToString(name[:size])))
				if filepath.Base(path) != "night-island.exe" {
					json.NewEncoder(c).Encode(islandState{Version: 1, Access: "denied"})
					return
				}
				var created, exited, kernel, cpu windows.Filetime
				if windows.GetProcessTimes(process, &created, &exited, &kernel, &cpu) != nil {
					return
				}
				key := fmt.Sprintf("%d/%d/%d", pid, created.HighDateTime, created.LowDateTime)
				cacheMu.Lock()
				peer, found := cache[key]
				cacheMu.Unlock()
				if !found {
					file, err := os.Open(path)
					if err != nil {
						return
					}
					info, statErr := file.Stat()
					if statErr != nil || info.Size() <= 0 || info.Size() > 128<<20 {
						file.Close()
						return
					}
					hash := sha256.New()
					_, err = io.Copy(hash, io.LimitReader(file, 128<<20))
					file.Close()
					if err != nil {
						return
					}
					peer = islandPeer{Path: path, Hash: hex.EncodeToString(hash.Sum(nil)), User: user}
					cacheMu.Lock()
					if len(cache) > 16 {
						clear(cache)
					}
					cache[key] = peer
					cacheMu.Unlock()
				}
				b := a.island()
				b.mu.Lock()
				b.pending = peer
				b.pendingAt = time.Now()
				b.mu.Unlock()
				_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
				line, err := bufio.NewReader(io.LimitReader(c, 4097)).ReadBytes('\n')
				if err != nil || len(line) > 4096 {
					return
				}
				var request struct {
					Action   string `json:"action"`
					ServerID string `json:"serverId"`
				}
				decoder := json.NewDecoder(strings.NewReader(string(line)))
				decoder.DisallowUnknownFields()
				if decoder.Decode(&request) != nil || len(request.ServerID) > 256 {
					return
				}
				operation, stop := context.WithTimeout(ctx, 40*time.Second)
				defer stop()
				clients.Store(c, func() { stop(); c.Close() })
				state := a.islandCommand(operation, peer, request.Action, request.ServerID)
				b.mu.Lock()
				if !b.allowed(peer) {
					state = b.deniedLocked()
				}
				b.mu.Unlock()
				_ = c.SetWriteDeadline(time.Now().Add(2 * time.Second))
				_ = json.NewEncoder(c).Encode(state)
			}(connection)
		}
	}()
	return func() {
		cancel()
		listener.Close()
		clients.Range(func(key, value any) bool { value.(func())(); return true })
	}, nil
}
