package mobile

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
	"net"
	"net/http"
	"net/url"
	"strings"
	"svoi/internal/speedtest"
	"sync"
	"time"
)

type mobileSpeedJob struct {
	mu               sync.Mutex
	id, group, state string
	results          []speedtest.Result
	cancel           context.CancelFunc
	done             chan struct{}
}
type speedProfile struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Protocol    string `json:"protocol"`
	FullProfile bool   `json:"fullProfile"`
}

var speedGuard sync.Mutex
var activeSpeed *mobileSpeedJob

func CancelSpeed() {
	speedGuard.Lock()
	job := activeSpeed
	speedGuard.Unlock()
	if job != nil {
		job.cancel()
	}
}
func speedReply(status int, body any) string {
	data, _ := json.Marshal(map[string]any{"status": status, "body": body})
	return string(data)
}
func speedError(status int, message string) string {
	return speedReply(status, map[string]string{"error": message})
}
func (s *Session) speedRequest(method, path, token, body string) string {
	u, err := url.Parse(path)
	if err != nil {
		return speedError(400, "Некорректный запрос")
	}
	var in struct {
		ServerIDs []string `json:"serverIds"`
	}
	start := method == "POST" && u.Path == "/api/tools/speed/start"
	if start && (len(body) > 4096 || json.Unmarshal([]byte(body), &in) != nil || len(in.ServerIDs) > 3) {
		return speedError(400, "Выберите до трёх серверов")
	}
	group, metadata, err := s.app.SpeedSelection(token, in.ServerIDs)
	if err != nil {
		return speedError(400, err.Error())
	}
	if start {
		selected := []speedProfile{}
		for _, p := range metadata {
			selected = append(selected, speedProfile{ID: p.ID, Name: p.Name, Protocol: p.Protocol, FullProfile: p.FullProfile})
		}
		lifecycle.Lock()
		defer lifecycle.Unlock()
		if instance != nil {
			return speedError(409, "Отключите VPN перед сравнением скорости")
		}
		speedGuard.Lock()
		defer speedGuard.Unlock()
		if activeSpeed != nil {
			select {
			case <-activeSpeed.done:
			default:
				return speedError(429, "Уже идёт замер скорости")
			}
		}
		ctx, cancel := context.WithTimeout(context.Background(), 115*time.Second)
		var id [16]byte
		if _, err := rand.Read(id[:]); err != nil {
			cancel()
			return speedError(500, "Не удалось запустить проверку")
		}
		job := &mobileSpeedJob{id: hex.EncodeToString(id[:]), group: group, state: "running", cancel: cancel, done: make(chan struct{}), results: []speedtest.Result{{Name: "Без VPN", Protocol: "Напрямую", State: "queued"}}}
		for _, p := range selected {
			protocol := strings.ToUpper(p.Protocol)
			if p.FullProfile {
				protocol = "Профиль Xray"
			}
			job.results = append(job.results, speedtest.Result{ServerID: p.ID, Name: p.Name, Protocol: protocol, State: "queued"})
		}
		s.speedMu.Lock()
		s.speed = job
		s.speedMu.Unlock()
		activeSpeed = job
		go s.runSpeed(ctx, job, token, selected)
		return speedReply(200, map[string]string{"id": job.id})
	}
	s.speedMu.Lock()
	job := s.speed
	s.speedMu.Unlock()
	if job == nil {
		return speedError(404, "Замер ещё не запускался")
	}
	if method == "POST" && u.Path == "/api/tools/speed/cancel" {
		job.cancel()
		return speedReply(200, map[string]string{"state": "cancelling"})
	}
	if method != "GET" || u.Path != "/api/tools/speed/status" {
		return speedError(404, "Инструмент не найден")
	}
	if job.group != group || u.Query().Get("id") != job.id {
		return speedError(404, "Результат недоступен")
	}
	job.mu.Lock()
	defer job.mu.Unlock()
	return speedReply(200, map[string]any{"id": job.id, "state": job.state, "results": job.results, "testNode": "svoi.space", "maxBytesPerRoute": 48 << 20})
}
func (s *Session) runSpeed(ctx context.Context, job *mobileSpeedJob, token string, profiles []speedProfile) {
	defer close(job.done)
	defer job.cancel()
	defer func() {
		speedGuard.Lock()
		if activeSpeed == job {
			activeSpeed = nil
		}
		speedGuard.Unlock()
	}()
	endpoint := s.speedEndpoint
	if endpoint == "" {
		endpoint = "https://svoi.space" + speedtest.Prefix
	}
	policy := speedtest.DefaultPolicy
	if s.speedPolicy != nil {
		policy = *s.speedPolicy
	}
	for i := range job.results {
		if ctx.Err() != nil {
			break
		}
		job.mu.Lock()
		job.results[i].State = "running"
		job.results[i].Phase = "preparing"
		job.mu.Unlock()
		route, cancel := context.WithTimeout(ctx, 26*time.Second)
		var raw string
		var err error
		if i > 0 {
			raw, err = s.app.SpeedConfig(token, profiles[i-1].ID)
		}
		var transport *http.Transport
		var cleanup func()
		if err == nil {
			transport, cleanup, err = mobileSpeedTransport(route, raw)
		}
		result := speedtest.Result{State: "error"}
		if err != nil {
			result.Error = "Не удалось подготовить профиль. Обновите подписку или выберите другой сервер."
		} else {
			result = speedtest.Measure(route, transport, endpoint, policy, func(u speedtest.Update) {
				job.mu.Lock()
				defer job.mu.Unlock()
				r := &job.results[i]
				r.Phase = u.Phase
				if u.Phase == "download" {
					v := u.Mbps
					r.Download = &v
					r.DownloadBytes = u.Bytes
					r.DownloadSamples = u.Samples
				}
				if u.Phase == "upload" {
					v := u.Mbps
					r.Upload = &v
					r.UploadBytes = u.Bytes
					r.UploadSamples = u.Samples
				}
			})
			cleanup()
		}
		if ctx.Err() != nil {
			result.State = "cancelled"
			result.Error = ""
		} else if route.Err() != nil {
			result.State = "error"
			result.Error = "Маршрут не успел ответить. Повторите замер или выберите другой сервер."
		}
		cancel()
		job.mu.Lock()
		old := job.results[i]
		result.Name = old.Name
		result.ServerID = old.ServerID
		result.Protocol = old.Protocol
		job.results[i] = result
		job.mu.Unlock()
	}
	job.mu.Lock()
	defer job.mu.Unlock()
	job.state = "done"
	if ctx.Err() != nil {
		job.state = "cancelled"
		for i := range job.results {
			if job.results[i].State == "running" || job.results[i].State == "queued" {
				job.results[i].State = "cancelled"
			}
		}
	}
}
func mobileSpeedTransport(ctx context.Context, raw string) (*http.Transport, func(), error) {
	t := &http.Transport{Proxy: nil, DisableCompression: true, TLSHandshakeTimeout: 4 * time.Second, ResponseHeaderTimeout: 5 * time.Second, MaxConnsPerHost: 2, MaxIdleConnsPerHost: 2}
	if raw == "" {
		d := &net.Dialer{Timeout: 4 * time.Second}
		t.DialContext = d.DialContext
		return t, t.CloseIdleConnections, nil
	}
	var config map[string]any
	if err := json.Unmarshal([]byte(raw), &config); err != nil {
		return nil, nil, err
	}
	tag := ""
	inbounds, _ := config["inbounds"].([]any)
	for _, v := range inbounds {
		in, _ := v.(map[string]any)
		if in["protocol"] == "http" {
			tag, _ = in["tag"].(string)
		}
	}
	if tag == "" {
		return nil, nil, errors.New("HTTP route missing")
	}
	config["inbounds"] = []any{}
	config["log"] = map[string]any{"loglevel": "none"}
	data, err := json.Marshal(config)
	if err != nil {
		return nil, nil, err
	}
	setup, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	x, err := startProbeCore(setup, string(data))
	if err != nil {
		return nil, nil, err
	}
	t.DialContext = func(_ context.Context, _, address string) (net.Conn, error) {
		dest, err := xnet.ParseDestination("tcp:" + address)
		if err != nil {
			return nil, err
		}
		return core.Dial(session.ContextWithInbound(ctx, &session.Inbound{Tag: tag, Name: "http"}), x, dest)
	}
	return t, func() { t.CloseIdleConnections(); x.Close() }, nil
}
