package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"strings"
	"time"
)

var siteSlots = make(chan struct{}, 2)

type siteStep struct {
	Name      string `json:"name"`
	OK        bool   `json:"ok"`
	Responded bool   `json:"responded,omitempty"`
	MS        int64  `json:"ms"`
	Detail    string `json:"detail"`
}

func siteTarget(raw string) (*url.URL, error) {
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil || len(raw) > 2048 || u.Hostname() == "" || u.User != nil || u.Fragment != "" || (u.Scheme != "https" && u.Scheme != "http") || strings.ContainsAny(raw, "\r\n\t \\") {
		return nil, fail(400, "Введите HTTP(S)-адрес сайта без логина, пароля и фрагмента")
	}
	if ip, e := netip.ParseAddr(u.Hostname()); e == nil && !publicIP(ip) {
		return nil, fail(400, "Проверяются только публичные сайты")
	}
	return u, nil
}

func siteHTTP(ctx context.Context, target *url.URL, transport *http.Transport) siteStep {
	defer transport.CloseIdleConnections()
	step := siteStep{Name: strings.ToUpper(target.Scheme)}
	client := &http.Client{Transport: transport, Timeout: 6 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	req, _ := http.NewRequestWithContext(ctx, "GET", target.String(), nil)
	req.Header.Set("User-Agent", "SVOI-Site-Check/1")
	started := time.Now()
	resp, err := client.Do(req)
	step.MS = time.Since(started).Milliseconds()
	if err != nil {
		step.Detail = "Ответ не получен. Возможны недоступность сайта, ошибка TLS или ограничение сети."
		return step
	}
	defer resp.Body.Close()
	step.Responded = true
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	step.OK = resp.StatusCode >= 200 && resp.StatusCode < 400
	step.Detail = fmt.Sprintf("HTTP %d", resp.StatusCode)
	if resp.StatusCode >= 300 && resp.StatusCode < 400 {
		step.Detail += " · сайт ответил перенаправлением; следующий адрес не проверялся"
	}
	if resp.StatusCode == 401 || resp.StatusCode == 403 {
		step.Detail += " · сервер доступен, но отклонил запрос приложения"
	}
	return step
}

func siteDirect(ctx context.Context, target *url.URL) ([]siteStep, string, error) {
	dialer, label, err := siteDirectNetwork(ctx)
	if err != nil {
		return nil, "", err
	}
	if dialer.Resolver == nil {
		dialer.Resolver = net.DefaultResolver
	}
	lookup, cancel := context.WithTimeout(ctx, 3*time.Second)
	started := time.Now()
	ips, err := dialer.Resolver.LookupNetIP(lookup, "ip4", target.Hostname())
	cancel()
	dns := siteStep{Name: "DNS · IPv4", MS: time.Since(started).Milliseconds(), OK: err == nil && len(ips) > 0, Detail: "Адрес сайта не получен. Проверьте интернет и выбранный DNS."}
	if dns.OK {
		for _, ip := range ips {
			if !publicIP(ip) {
				return nil, label, fail(400, "DNS вернул непубличный адрес; проверка остановлена")
			}
		}
		dns.Detail = ips[0].String()
	}
	steps := []siteStep{dns}
	if !dns.OK {
		return steps, label, nil
	}
	port := target.Port()
	if port == "" {
		if target.Scheme == "https" {
			port = "443"
		} else {
			port = "80"
		}
	}
	address := net.JoinHostPort(ips[0].String(), port)
	started = time.Now()
	conn, err := dialer.DialContext(ctx, "tcp4", address)
	tcp := siteStep{Name: "TCP", OK: err == nil, MS: time.Since(started).Milliseconds(), Detail: "Соединение с сайтом не установлено"}
	if err == nil {
		conn.Close()
		tcp.Detail = "Соединение установлено"
	}
	steps = append(steps, tcp)
	if err != nil {
		return steps, label, nil
	}
	transport := &http.Transport{Proxy: nil, DisableKeepAlives: true, TLSHandshakeTimeout: 4 * time.Second, TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12}, DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return dialer.DialContext(ctx, "tcp4", address)
	}}
	return append(steps, siteHTTP(ctx, target, transport)), label, nil
}

func (a *App) siteAPI(w http.ResponseWriter, r *http.Request) error {
	if r.Method != "POST" || r.URL.Path != "/api/tools/site" {
		return fail(404, "Инструмент не найден")
	}
	var in struct {
		URL      string `json:"url"`
		Route    string `json:"route"`
		ServerID string `json:"serverId"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&in) != nil {
		return fail(400, "Некорректный адрес проверки")
	}
	target, err := siteTarget(strings.TrimSpace(in.URL))
	if err != nil {
		return err
	}
	if in.Route != "direct" && in.Route != "profile" {
		return fail(400, "Неизвестный маршрут проверки")
	}
	select {
	case siteSlots <- struct{}{}:
		defer func() { <-siteSlots }()
	default:
		return fail(429, "Уже выполняются две проверки сайта")
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	connectionKey := a.dnsConnectionKey()
	var steps []siteStep
	label := ""
	if in.Route == "direct" {
		steps, label, err = siteDirect(ctx, target)
	} else {
		if a.engine == nil || !a.engine.Status().Available {
			return fail(503, "Для проверки профиля нужно ядро Xray")
		}
		a.mu.Lock()
		g, _, authErr := a.auth(r)
		var server ServerConfig
		found := false
		if authErr == nil {
			for _, s := range g.Servers {
				if s.ID == in.ServerID {
					server = s
					found = true
					break
				}
			}
		}
		a.mu.Unlock()
		if authErr != nil {
			return authErr
		}
		if !found {
			return fail(404, "Выберите сервер для проверки")
		}
		active := a.engine.snapshot(false)
		if active.State == "running" && active.ServerID == in.ServerID {
			proxy, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", active.HTTPPort))
			steps = []siteStep{siteHTTP(ctx, target, &http.Transport{Proxy: http.ProxyURL(proxy), DisableKeepAlives: true, TLSHandshakeTimeout: 4 * time.Second})}
			label = "Активный профиль · " + server.Name
		} else {
			if active.State == "running" && active.Mode == "tun" {
				return fail(409, "Для проверки другого профиля отключите TUN или выберите активный сервер")
			}
			dir, e := os.MkdirTemp(a.engine.dir, "site-")
			if e != nil {
				return e
			}
			defer os.RemoveAll(dir)
			probe := &Engine{binary: a.engine.binary, dir: dir, status: EngineStatus{State: "stopped", Available: true}}
			defer probe.Stop()
			server.RuntimeDirectDomains = a.localSettings().DirectDomains
			startup, stopStartup := context.WithTimeout(ctx, 5*time.Second)
			err = probe.startContext(startup, server, "local")
			stopStartup()
			if err == nil {
				proxy, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", probe.Status().HTTPPort))
				steps = []siteStep{siteHTTP(ctx, target, &http.Transport{Proxy: http.ProxyURL(proxy), DisableKeepAlives: true, TLSHandshakeTimeout: 4 * time.Second})}
				label = server.Name
			}
		}
	}
	if err != nil {
		return err
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if connectionKey != a.dnsConnectionKey() {
		return fail(409, "Подключение изменилось во время проверки. Повторите тест")
	}
	writeJSON(w, 200, map[string]any{"route": in.Route, "label": label, "steps": steps, "host": target.Hostname(), "checkedAt": time.Now().UTC()})
	return nil
}
