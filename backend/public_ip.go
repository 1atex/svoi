package backend

import (
	"context"
	"io"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"time"
)

type PublicIPResult struct {
	IP        string    `json:"ip"`
	Via       string    `json:"via"`
	CheckedAt time.Time `json:"checkedAt"`
}

func (e *Engine) PublicIP(parent context.Context) (PublicIPResult, error) {
	e.op.Lock()
	e.mu.Lock()
	s := e.status
	if s.State == "starting" || s.State == "stopping" {
		e.mu.Unlock()
		e.op.Unlock()
		return PublicIPResult{}, fail(409, "Дождитесь переключения VPN")
	}
	if e.ipCancel != nil {
		e.ipCancel()
	}
	ctx, cancel := context.WithTimeout(parent, 5*time.Second)
	e.ipCancel = cancel
	e.ipRevision++
	revision := e.ipRevision
	endpoint := e.ipURL
	e.mu.Unlock()
	e.op.Unlock()
	defer cancel()
	if endpoint == "" {
		endpoint = "https://api64.ipify.org"
	}
	transport := &http.Transport{TLSHandshakeTimeout: 4 * time.Second}
	via := "network"
	if s.State == "running" {
		via = "tun"
		if s.Mode != "tun" {
			via = "proxy"
			if s.HTTPPort < 1 {
				return PublicIPResult{}, fail(409, "Прокси ещё не готов")
			}
			proxy, _ := url.Parse("http://127.0.0.1:" + strconv.Itoa(s.HTTPPort))
			transport.Proxy = http.ProxyURL(proxy)
		}
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return PublicIPResult{}, fail(502, "Некорректный адрес проверки IP")
	}
	response, err := client.Do(req)
	if err != nil {
		return PublicIPResult{}, fail(502, "Не удалось определить внешний IP. Повторите проверку.")
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 65))
	address, parseErr := netip.ParseAddr(strings.TrimSpace(string(body)))
	if err != nil || response.StatusCode != 200 || len(body) > 64 || parseErr != nil || !address.IsGlobalUnicast() || address.IsPrivate() || address.Zone() != "" {
		return PublicIPResult{}, fail(502, "Сервис определения IP не вернул корректный внешний адрес")
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.ipRevision != revision || ctx.Err() != nil || e.status.State != s.State || e.status.ServerID != s.ServerID || e.status.Mode != s.Mode || e.status.StartedAt != s.StartedAt {
		return PublicIPResult{}, fail(409, "Подключение изменилось. Проверка IP отменена.")
	}
	e.ipCancel = nil
	return PublicIPResult{IP: address.Unmap().String(), Via: via, CheckedAt: time.Now().UTC()}, nil
}
