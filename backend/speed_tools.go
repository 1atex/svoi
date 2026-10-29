package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"svoi/internal/speedtest"
	"sync"
	"time"
)

type speedResult = speedtest.Result
type speedRun struct {
	mu               sync.Mutex
	id, group, state string
	results          []speedResult
	cancel           context.CancelFunc
	done             chan struct{}
}
type speedPolicy = speedtest.Policy

var defaultSpeedPolicy = speedtest.DefaultPolicy

func (a *App) cancelSpeed() {
	a.speedMu.Lock()
	job := a.speed
	a.speedMu.Unlock()
	if job != nil {
		job.cancel()
	}
}

func (a *App) closeSpeed() {
	a.cancelSpeed()
	a.speedMu.Lock()
	job := a.speed
	a.speedMu.Unlock()
	if job != nil {
		select {
		case <-job.done:
		case <-time.After(3 * time.Second):
		}
	}
}

func (a *App) speedConnectionKey() string {
	if a.engine == nil {
		return ""
	}
	a.engine.mu.Lock()
	defer a.engine.mu.Unlock()
	s := a.engine.status
	return fmt.Sprint(s.State, s.Mode, s.ServerID, s.StartedAt)
}

func (a *App) speedAPI(w http.ResponseWriter, r *http.Request) error {
	a.mu.Lock()
	g, _, err := a.auth(r)
	group := ""
	var servers []ServerConfig
	if err == nil {
		group = g.ID
		servers = append(servers, g.Servers...)
	}
	a.mu.Unlock()
	if err != nil {
		return err
	}
	if r.Method == "POST" && r.URL.Path == "/api/tools/speed/start" {
		var in struct {
			ServerIDs []string `json:"serverIds"`
		}
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&in) != nil || len(in.ServerIDs) > 3 {
			return fail(400, "Выберите не больше трёх серверов")
		}
		if r.Context().Err() != nil {
			return r.Context().Err()
		}
		chosen := []ServerConfig{}
		seen := map[string]bool{}
		for _, id := range in.ServerIDs {
			if seen[id] {
				return fail(400, "Сервер выбран дважды")
			}
			seen[id] = true
			found := false
			for _, s := range servers {
				if s.ID == id {
					chosen = append(chosen, s)
					found = true
					break
				}
			}
			if !found {
				return fail(404, "Список серверов изменился. Выберите их заново.")
			}
		}
		a.networkOp.Lock()
		defer a.networkOp.Unlock()
		if a.engine != nil {
			s := a.engine.snapshot(false)
			if s.State == "starting" || s.State == "stopping" || s.State == "running" && s.Mode == "tun" {
				return fail(409, "Для сравнения отключите TUN. Приложение не меняет подключение автоматически.")
			}
			if len(chosen) > 0 && !s.Available {
				return fail(503, "Для замера серверов установите полную сборку SVOI с ядром Xray")
			}
		}
		if len(chosen) > 0 && a.engine == nil {
			return fail(503, "Для замера серверов нужно ядро Xray")
		}
		a.speedMu.Lock()
		defer a.speedMu.Unlock()
		if a.speed != nil {
			select {
			case <-a.speed.done:
			default:
				return fail(429, "Уже идёт замер скорости. Остановите его перед новым запуском.")
			}
		}
		ctx, cancel := context.WithTimeout(context.Background(), 115*time.Second)
		job := &speedRun{id: secret(), group: group, state: "running", cancel: cancel, done: make(chan struct{}), results: []speedResult{{Name: "Без VPN", State: "queued", Protocol: "Напрямую"}}}
		for _, s := range chosen {
			protocol := strings.ToUpper(s.Protocol)
			if s.FullProfile {
				protocol = "Профиль Xray"
			}
			job.results = append(job.results, speedResult{ServerID: s.ID, Name: s.Name, Protocol: protocol, State: "queued"})
		}
		a.speed = job
		go a.runSpeed(ctx, job, chosen)
		writeJSON(w, 200, object{"id": job.id})
		return nil
	}
	a.speedMu.Lock()
	job := a.speed
	a.speedMu.Unlock()
	if job == nil {
		return fail(404, "Замер ещё не запускался")
	}
	if r.Method == "POST" && r.URL.Path == "/api/tools/speed/cancel" {
		job.cancel()
		writeJSON(w, 200, object{"state": "cancelling"})
		return nil
	}
	if r.Method != "GET" || r.URL.Path != "/api/tools/speed/status" {
		return fail(404, "Инструмент не найден")
	}
	if job.group != group || r.URL.Query().Get("id") != job.id {
		return fail(404, "Результат этого замера недоступен")
	}
	job.mu.Lock()
	defer job.mu.Unlock()
	writeJSON(w, 200, object{"id": job.id, "state": job.state, "results": job.results, "testNode": "svoi.space", "maxBytesPerRoute": defaultSpeedPolicy.Download + defaultSpeedPolicy.Upload})
	return nil
}

func (a *App) runSpeed(ctx context.Context, job *speedRun, servers []ServerConfig) {
	defer close(job.done)
	defer job.cancel()
	key := a.speedConnectionKey()
	monitorDone := make(chan struct{})
	defer close(monitorDone)
	go func() {
		timer := time.NewTicker(150 * time.Millisecond)
		defer timer.Stop()
		for {
			select {
			case <-monitorDone:
				return
			case <-ctx.Done():
				return
			case <-timer.C:
				if key != a.speedConnectionKey() {
					job.cancel()
					return
				}
			}
		}
	}()
	endpoint := a.speedEndpoint
	if endpoint == "" {
		endpoint = "https://svoi.space" + speedtest.Prefix
	}
	policy := defaultSpeedPolicy
	if a.speedPolicy != nil {
		policy = *a.speedPolicy
	}
	for i := range job.results {
		if ctx.Err() != nil {
			break
		}
		job.mu.Lock()
		job.results[i].State = "running"
		job.results[i].Phase = "preparing"
		job.mu.Unlock()
		routeCtx, cancel := context.WithTimeout(ctx, 26*time.Second)
		transport, cleanup, err := a.speedTransport(routeCtx, i, servers)
		if err == nil {
			result := speedtest.Measure(routeCtx, transport, endpoint, policy, func(update speedtest.Update) {
				phase, n, mbps := update.Phase, update.Bytes, update.Mbps
				job.mu.Lock()
				defer job.mu.Unlock()
				job.results[i].Phase = phase
				if phase == "download" {
					job.results[i].DownloadSamples = update.Samples
					job.results[i].DownloadBytes = n
					job.results[i].Download = &mbps
				}
				if phase == "upload" {
					job.results[i].UploadSamples = update.Samples
					job.results[i].UploadBytes = n
					job.results[i].Upload = &mbps
				}
			})
			job.mu.Lock()
			old := job.results[i]
			if ctx.Err() != nil {
				result.State = "cancelled"
				result.Phase = ""
				result.Error = ""
			} else if routeCtx.Err() != nil {
				result.State = "error"
				result.Error = "Маршрут не успел ответить. Повторите замер или выберите другой сервер."
			}
			result.ServerID = old.ServerID
			result.Name = old.Name
			result.Protocol = old.Protocol
			job.results[i] = result
			job.mu.Unlock()
			cleanup()
		} else {
			job.mu.Lock()
			job.results[i].State = "error"
			job.results[i].Error = err.Error()
			job.mu.Unlock()
		}
		cancel()
	}
	job.mu.Lock()
	defer job.mu.Unlock()
	job.state = "done"
	if ctx.Err() != nil {
		job.state = "cancelled"
		for i := range job.results {
			if job.results[i].State == "queued" || job.results[i].State == "running" {
				job.results[i].State = "cancelled"
				job.results[i].Phase = ""
			}
		}
	}
}

func (a *App) speedTransport(ctx context.Context, index int, servers []ServerConfig) (*http.Transport, func(), error) {
	transport := &http.Transport{Proxy: nil, DisableCompression: true, TLSHandshakeTimeout: 4 * time.Second, ResponseHeaderTimeout: 5 * time.Second, MaxConnsPerHost: 2, MaxIdleConnsPerHost: 2}
	if index == 0 {
		dialer := a.speedDirectDialer
		var err error
		if dialer == nil {
			dialer, _, err = siteDirectNetwork(ctx)
		}
		if err != nil {
			return nil, nil, fail(502, "Не найден прямой доступ к сети. Проверьте подключение и отключите сторонний VPN.")
		}
		transport.DialContext = func(ctx context.Context, _, address string) (net.Conn, error) {
			return dialer.DialContext(ctx, "tcp4", address)
		}
		return transport, transport.CloseIdleConnections, nil
	}
	server, err := speedServerConfig(servers[index-1])
	if err != nil {
		return nil, nil, err
	}
	dir, err := os.MkdirTemp(a.engine.dir, "speed-")
	if err != nil {
		return nil, nil, err
	}
	probe := a.engine.probeEngine(dir)
	cleanup := func() { transport.CloseIdleConnections(); _ = probe.Stop(); _ = os.RemoveAll(dir) }
	startup, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err = probe.startContext(startup, server, "local"); err != nil {
		cleanup()
		return nil, nil, fail(502, "Не удалось запустить профиль. Проверьте конфигурацию или выберите другой сервер.")
	}
	proxy, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", probe.snapshot(false).HTTPPort))
	transport.Proxy = http.ProxyURL(proxy)
	return transport, cleanup, nil
}

func measureSpeed(ctx context.Context, t *http.Transport, endpoint string, policy speedPolicy, progress func(string, int64, float64)) speedResult {
	return speedtest.Measure(ctx, t, endpoint, policy, func(u speedtest.Update) { progress(u.Phase, u.Bytes, u.Mbps) })
}

var speedTransfer = speedtest.Transfer
