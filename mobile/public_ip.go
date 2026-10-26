package mobile

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"time"
)

type PublicIPRequest struct {
	ctx    context.Context
	cancel context.CancelFunc
	via    string
	once   sync.Once
}

var ipCancel context.CancelFunc

func NewPublicIPRequest() *PublicIPRequest {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if ipCancel != nil {
		ipCancel()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	ipCancel = cancel
	via := "network"
	if instance != nil {
		via = "tun"
	}
	return &PublicIPRequest{ctx: ctx, cancel: cancel, via: via}
}

func (p *PublicIPRequest) Cancel() { p.cancel() }

func (p *PublicIPRequest) Run() (string, error) {
	result := ""
	err := errors.New("Проверка уже завершена")
	p.once.Do(func() {
		defer p.cancel()
		var ip string
		ip, err = fetchPublicIP(p.ctx, "https://api64.ipify.org")
		if err == nil {
			data, _ := json.Marshal(map[string]any{"ip": ip, "via": p.via, "checkedAt": time.Now().UTC()})
			result = string(data)
		}
	})
	return result, err
}

func fetchPublicIP(ctx context.Context, endpoint string) (string, error) {
	transport := &http.Transport{Proxy: nil, DisableKeepAlives: true, TLSHandshakeTimeout: 4 * time.Second}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return "", err
	}
	response, err := client.Do(req)
	if err != nil {
		return "", errors.New("Не удалось определить внешний IP")
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 65))
	address, parseErr := netip.ParseAddr(strings.TrimSpace(string(body)))
	if err != nil || response.StatusCode != 200 || len(body) > 64 || parseErr != nil || !address.IsGlobalUnicast() || address.IsPrivate() || address.Zone() != "" {
		return "", errors.New("Сервис не вернул корректный внешний IP")
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	return address.Unmap().String(), nil
}
