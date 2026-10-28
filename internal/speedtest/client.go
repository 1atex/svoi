package speedtest

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

type Sample struct {
	Seconds float64 `json:"seconds"`
	Mbps    float64 `json:"mbps"`
}
type Update struct {
	Phase   string
	Bytes   int64
	Mbps    float64
	Samples []Sample
}
type Result struct {
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
	DownloadSamples    []Sample `json:"downloadSamples,omitempty"`
	UploadSamples      []Sample `json:"uploadSamples,omitempty"`
}
type Policy struct {
	Duration         time.Duration
	Download, Upload int64
}

var DefaultPolicy = Policy{4 * time.Second, 32 << 20, 16 << 20}

func Client(transport *http.Transport) *http.Client {
	return &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}
func response(resp *http.Response, err error) error {
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

func Measure(ctx context.Context, transport *http.Transport, endpoint string, policy Policy, progress func(Update)) Result {
	result := Result{State: "error"}
	var phaseStart time.Time
	var previousPhase string
	var previousTime time.Duration
	var previousBytes int64
	var history []Sample
	notify := func(phase string, n int64, mbps float64) {
		if phase != previousPhase {
			previousPhase = phase
			phaseStart = time.Now()
			previousTime = 0
			previousBytes = 0
			history = nil
		} else if phase == "download" || phase == "upload" {
			elapsed := time.Since(phaseStart)
			interval := elapsed - previousTime
			if interval >= time.Microsecond && len(history) < 48 {
				history = append(history, Sample{Seconds: elapsed.Seconds(), Mbps: float64(n-previousBytes) * 8 / interval.Seconds() / 1e6})
				previousTime = elapsed
				previousBytes = n
			}
		}
		points := append([]Sample(nil), history...)
		if phase == "download" {
			result.DownloadSamples = points
		}
		if phase == "upload" {
			result.UploadSamples = points
		}
		progress(Update{Phase: phase, Bytes: n, Mbps: mbps, Samples: points})
	}
	client := Client(transport)
	samples := []float64{}
	notify("latency", 0, 0)
	for i := 0; i < 4; i++ {
		requestCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
		req, _ := http.NewRequestWithContext(requestCtx, "GET", endpoint+"ping", nil)
		req.Header.Set("User-Agent", "SVOI-Speed/1")
		req.Header.Set("Cache-Control", "no-store")
		started := time.Now()
		resp, err := client.Do(req)
		elapsed := float64(time.Since(started).Microseconds()) / 1000
		checked := response(resp, err)
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
	down, n, duration, err := Transfer(ctx, client, endpoint, "download", policy.Duration, policy.Download, notify)
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
	up, n, duration, err := Transfer(ctx, client, endpoint, "upload", policy.Duration, policy.Upload, notify)
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

func Transfer(parent context.Context, client *http.Client, endpoint, direction string, duration time.Duration, limit int64, progress func(string, int64, float64)) (float64, int64, time.Duration, error) {
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
	progress(direction, 0, 0)
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
				checked := response(resp, err)
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
