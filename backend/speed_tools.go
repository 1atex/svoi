package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"svoi/internal/speedtest"
	"sync"
	"sync/atomic"
	"time"
)

type speedResult struct {
	ServerID           string   `json:"serverId"`
	Name               string   `json:"name"`
	Protocol           string   `json:"protocol"`
	State              string   `json:"state"`
	Phase              string   `json:"phase"`
	Error              string   `json:"error,omitempty"`
	Warning            string   `json:"warning,omitempty"`
	Download           *float64 `json:"downloadMbps,omitempty"`
	Upload             *float64 `json:"uploadMbps,omitempty"`
	Latency            *float64 `json:"latencyMs,omitempty"`
	DownloadBytes      int64    `json:"downloadBytes"`
	UploadBytes        int64    `json:"uploadBytes"`
	DownloadSeconds    float64  `json:"downloadSeconds"`
	UploadSeconds      float64  `json:"uploadSeconds"`
	DownloadFullWindow bool     `json:"downloadFullWindow"`
	UploadFullWindow   bool     `json:"uploadFullWindow"`
	DownloadCapped     bool     `json:"downloadCapped"`
	UploadCapped       bool     `json:"uploadCapped"`
}
type speedRun struct {
	mu               sync.Mutex
	id, group, state string
	results          []speedResult
	cancel           context.CancelFunc
	done             chan struct{}
}
type speedPolicy struct {
	Duration         time.Duration
	Download, Upload int64
}

var defaultSpeedPolicy = speedPolicy{4 * time.Second, 32 << 20, 16 << 20}

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
			result := measureSpeed(routeCtx, transport, endpoint, policy, func(phase string, n int64, mbps float64) {
				job.mu.Lock()
				defer job.mu.Unlock()
				job.results[i].Phase = phase
				if phase == "download" {
					job.results[i].DownloadBytes = n
					job.results[i].Download = &mbps
				}
				if phase == "upload" {
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
	probe := &Engine{binary: a.engine.binary, dir: dir, status: EngineStatus{State: "stopped", Available: true}}
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

func speedClient(transport *http.Transport) *http.Client {
	return &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}
func speedResponse(resp *http.Response, err error) error {
	if err != nil {
		return fmt.Errorf("Нет связи с тестовым узлом. Проверьте интернет или выберите другой сервер.")
	}
	if resp.StatusCode == 429 || resp.StatusCode == 503 && resp.Header.Get("X-SVOI-Speed") == "1" {
		return fmt.Errorf("Тестовый узел занят. Повторите замер через минуту.")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 || resp.Header.Get("X-SVOI-Speed") != "1" {
		return fmt.Errorf("Тестовый узел вернул неверный ответ. Повторите позже.")
	}
	return nil
}

func measureSpeed(ctx context.Context, transport *http.Transport, endpoint string, policy speedPolicy, progress func(string, int64, float64)) speedResult {
	result := speedResult{State: "error"}
	client := speedClient(transport)
	samples := []float64{}
	progress("latency", 0, 0)
	for i := 0; i < 4; i++ {
		requestCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
		req, _ := http.NewRequestWithContext(requestCtx, "GET", endpoint+"ping", nil)
		req.Header.Set("User-Agent", "SVOI-Speed/1")
		req.Header.Set("Cache-Control", "no-store")
		started := time.Now()
		resp, err := client.Do(req)
		elapsed := float64(time.Since(started).Microseconds()) / 1000
		checked := speedResponse(resp, err)
		if resp != nil {
			resp.Body.Close()
		}
		cancel()
		if checked != nil {
			result.Error = checked.Error()
			return result
		}
		if i > 0 {
			samples = append(samples, elapsed)
		}
	}
	sort.Float64s(samples)
	latency := samples[len(samples)/2]
	result.Latency = &latency
	down, n, duration, err := speedTransfer(ctx, client, endpoint, "download", policy.Duration, policy.Download, progress)
	result.DownloadBytes = n
	result.DownloadSeconds = duration.Seconds()
	result.DownloadCapped = n >= policy.Download
	result.DownloadFullWindow = err == nil && duration >= max(3*time.Second, policy.Duration*9/10)
	if n > 0 {
		result.Download = &down
	}
	if err != nil {
		result.Error = err.Error()
		return result
	}
	if !result.DownloadFullWindow {
		result.Warning = "Короткая выборка загрузки: скорость ориентировочная. Процент сравнения не рассчитывается."
	}
	up, n, duration, err := speedTransfer(ctx, client, endpoint, "upload", policy.Duration, policy.Upload, progress)
	result.UploadBytes = n
	result.UploadSeconds = duration.Seconds()
	result.UploadCapped = n >= policy.Upload
	result.UploadFullWindow = err == nil && duration >= max(3*time.Second, policy.Duration*9/10)
	if err == nil && !result.UploadFullWindow {
		if result.Warning != "" {
			result.Warning += " "
		}
		result.Warning += "Короткая выборка отдачи: скорость ориентировочная."
	}
	if n > 0 {
		result.Upload = &up
	}
	if err != nil {
		result.Error = err.Error()
		return result
	}
	result.State = "done"
	result.Phase = "done"
	return result
}

func speedTransfer(parent context.Context, client *http.Client, endpoint, direction string, duration time.Duration, limit int64, progress func(string, int64, float64)) (float64, int64, time.Duration, error) {
	ctx, cancel := context.WithTimeout(parent, duration)
	defer cancel()
	var transferred atomic.Int64
	failures := make(chan error, 2)
	var wg sync.WaitGroup
	payload := make([]byte, 512<<10)
	if _, err := rand.Read(payload); err != nil {
		return 0, 0, 0, err
	}
	started := time.Now()
	tickerDone := make(chan struct{})
	tickerExited := make(chan struct{})
	go func() {
		defer close(tickerExited)
		ticker := time.NewTicker(300 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-tickerDone:
				return
			case <-ticker.C:
				n := transferred.Load()
				progress(direction, n, float64(n)*8/max(time.Since(started), time.Microsecond).Seconds()/1e6)
			}
		}
	}()
	for worker := 0; worker < 2; worker++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			remaining := limit / 2
			chunk := int64(64 << 10)
			if direction == "download" {
				chunk = 2 << 20
			}
			for remaining > 0 && ctx.Err() == nil {
				size := min(chunk, remaining)
				method := "GET"
				target := endpoint + "download?bytes=" + fmt.Sprint(size)
				var body io.Reader
				if direction == "upload" {
					method = "POST"
					target = endpoint + "upload"
					body = bytes.NewReader(payload[:size])
				}
				req, _ := http.NewRequestWithContext(ctx, method, target, body)
				req.Header.Set("Cache-Control", "no-store")
				req.Header.Set("User-Agent", "SVOI-Speed/1")
				resp, err := client.Do(req)
				checked := speedResponse(resp, err)
				if checked != nil {
					if resp != nil {
						resp.Body.Close()
					}
					if ctx.Err() == nil {
						failures <- checked
					}
					return
				}
				if resp.Header.Get("Content-Encoding") != "" && resp.Header.Get("Content-Encoding") != "identity" {
					resp.Body.Close()
					failures <- errors.New("Тестовый узел сжимает данные: замер остановлен.")
					return
				}
				if direction == "download" {
					if resp.ContentLength != size {
						resp.Body.Close()
						failures <- errors.New("Неверный размер данных тестового узла.")
						return
					}
					buffer := make([]byte, 32<<10)
					var read int64
					for {
						n, e := resp.Body.Read(buffer)
						read += int64(n)
						transferred.Add(int64(n))
						if e != nil {
							err = e
							break
						}
					}
					resp.Body.Close()
					remaining -= read
					if err != io.EOF && ctx.Err() == nil {
						failures <- errors.New("Загрузка прервалась. Повторите замер.")
						return
					}
				} else {
					var ack struct {
						Bytes int64 `json:"bytes"`
					}
					err = json.NewDecoder(io.LimitReader(resp.Body, 256)).Decode(&ack)
					resp.Body.Close()
					if err != nil || ack.Bytes != size {
						if ctx.Err() == nil {
							failures <- errors.New("Не удалось подтвердить отправку данных.")
						}
						return
					}
					transferred.Add(size)
					remaining -= size
					chunk = min(int64(len(payload)), chunk*4)
				}
			}
		}()
	}
	wg.Wait()
	close(tickerDone)
	<-tickerExited
	elapsed := max(time.Since(started), time.Microsecond)
	n := transferred.Load()
	mbps := float64(n) * 8 / elapsed.Seconds() / 1e6
	progress(direction, n, mbps)
	if parent.Err() != nil {
		return mbps, n, elapsed, parent.Err()
	}
	select {
	case err := <-failures:
		return mbps, n, elapsed, err
	default:
	}
	if n == 0 {
		return 0, 0, elapsed, errors.New("Не удалось передать данные. Проверьте профиль и повторите замер.")
	}
	return mbps, n, elapsed, nil
}
