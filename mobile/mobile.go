package mobile

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/main/distro/all"
	"github.com/xtls/xray-core/transport/internet"
	"svoi/backend"
	"svoi/internal/speedtest"
)

type Protector interface{ Protect(fd int32) bool }
type Session struct {
	app           *backend.MobileApp
	speedMu       sync.Mutex
	speed         *mobileSpeedJob
	speedEndpoint string
	speedPolicy   *speedtest.Policy
}

func NewSession(directory string) (*Session, error) {
	os.Setenv("XRAY_LOCATION_ASSET", filepath.Join(directory, "core"))
	registerNetwork()
	a, err := backend.OpenMobile(directory)
	if err != nil {
		return nil, err
	}
	return &Session{app: a}, nil
}
func (s *Session) Request(method, path, token, body string) string {
	if strings.HasPrefix(path, "/api/tools/speed/") {
		return s.speedRequest(method, path, token, body)
	}
	return s.app.Request(method, path, token, body)
}
func (s *Session) Config(token, serverID string) (string, error) {
	return s.app.TunnelConfig(token, serverID)
}
func Version() string { return core.Version() }

var lifecycle sync.Mutex
var instance *core.Instance
var socketMu sync.RWMutex
var protector Protector
var register sync.Once

func protect(_ string, _ string, conn syscall.RawConn) error {
	socketMu.RLock()
	p := protector
	socketMu.RUnlock()
	if p == nil {
		return nil
	}
	ok := false
	if err := conn.Control(func(fd uintptr) { ok = p.Protect(int32(fd)) }); err != nil {
		return err
	}
	if !ok {
		return errors.New("VPN socket protection failed")
	}
	return nil
}

func Start(config string, fd int32, assets string, callback Protector) error {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	CancelSpeed()
	if ipCancel != nil {
		ipCancel()
		ipCancel = nil
	}
	if instance != nil {
		return errors.New("VPN already running")
	}
	if fd < 0 || callback == nil {
		return errors.New("VPN permission is required")
	}
	socketMu.Lock()
	protector = callback
	socketMu.Unlock()
	registerNetwork()
	os.Setenv("XRAY_TUN_FD", strconv.Itoa(int(fd)))
	os.Setenv("XRAY_LOCATION_ASSET", assets)
	loaded, err := core.LoadConfig("json", strings.NewReader(config))
	if err != nil {
		clearProtector()
		return err
	}
	x, err := core.New(loaded)
	if err != nil {
		clearProtector()
		return err
	}
	if err = x.Start(); err != nil {
		_ = x.Close()
		clearProtector()
		return err
	}
	instance = x
	return nil
}

func registerNetwork() {
	register.Do(func() {
		_ = internet.RegisterDialerController(protect)
		net.DefaultResolver = &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			d := net.Dialer{Timeout: 5 * time.Second, Control: func(n, a string, c syscall.RawConn) error {
				socketMu.RLock()
				active := protector != nil
				socketMu.RUnlock()
				if active {
					return protect(n, a, c)
				}
				return nil
			}}
			return d.DialContext(ctx, network, "1.1.1.1:53")
		}}
	})
}
func clearProtector() { socketMu.Lock(); protector = nil; socketMu.Unlock() }
func Stop() error {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	CancelSpeed()
	if ipCancel != nil {
		ipCancel()
		ipCancel = nil
	}
	var err error
	if instance != nil {
		err = instance.Close()
		instance = nil
	}
	clearProtector()
	return err
}
func Check() (int64, error) {
	client := &http.Client{Timeout: 8 * time.Second, Transport: &http.Transport{Proxy: nil, DisableKeepAlives: true}}
	start := time.Now()
	response, err := client.Get("https://www.gstatic.com/generate_204")
	if err != nil {
		return 0, errors.New("Контрольный запрос не прошёл. Попробуйте другой сервер.")
	}
	defer response.Body.Close()
	if response.StatusCode != 204 {
		return 0, errors.New("Неожиданный ответ проверки соединения")
	}
	return time.Since(start).Milliseconds(), nil
}

func Diagnostics() string {
	var stats runtime.MemStats
	runtime.ReadMemStats(&stats)
	data, _ := json.Marshal(map[string]any{"heapBytes": stats.HeapAlloc, "heapInuseBytes": stats.HeapInuse, "goroutines": runtime.NumGoroutine(), "gcCount": stats.NumGC})
	return string(data)
}

func GoroutineDump() string {
	buffer := make([]byte, 256<<10)
	n := runtime.Stack(buffer, true)
	return string(buffer[:n])
}
