package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type checkTarget struct {
	Name, URL, Host string
	PingOnly        bool
}

func parseCheckTarget(name, value string) (checkTarget, error) {
	t := checkTarget{Name: name}
	if strings.HasPrefix(value, "PING:") {
		t.Host = strings.TrimPrefix(value, "PING:")
		t.PingOnly = true
	} else {
		u, e := url.Parse(value)
		if e != nil || u.Scheme != "https" || u.User != nil || u.Hostname() == "" || (u.Port() != "" && u.Port() != "443") {
			return t, fmt.Errorf("Некорректная HTTPS-цель %s", name)
		}
		t.URL = value
		t.Host = u.Hostname()
	}
	if len(t.Host) > 253 || !regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9.:-]*$`).MatchString(t.Host) {
		return t, fmt.Errorf("Некорректный адрес %s", name)
	}
	return t, nil
}
func standardTargets(folder string) ([]checkTarget, error) {
	targets := []checkTarget{}
	p := filepath.Join(folder, "utils", "targets.txt")
	if folder != "" {
		if b, e := os.ReadFile(p); e == nil {
			if len(b) > 128<<10 {
				return nil, fmt.Errorf("targets.txt слишком большой")
			}
			re := regexp.MustCompile(`^\s*([^#=]+?)\s*=\s*"([^"]+)"\s*$`)
			for _, line := range strings.Split(strings.TrimPrefix(string(b), "\ufeff"), "\n") {
				m := re.FindStringSubmatch(line)
				if m == nil {
					continue
				}
				t, e := parseCheckTarget(strings.TrimSpace(m[1]), m[2])
				if e != nil {
					return nil, e
				}
				targets = append(targets, t)
			}
		}
	}
	if len(targets) == 0 {
		for _, host := range []string{"discord.com", "gateway.discord.gg", "cdn.discordapp.com", "updates.discord.com", "www.youtube.com", "youtu.be", "i.ytimg.com", "redirector.googlevideo.com", "www.google.com", "www.gstatic.com", "www.cloudflare.com", "cdnjs.cloudflare.com"} {
			t, _ := parseCheckTarget(host, "https://"+host)
			targets = append(targets, t)
		}
		for _, ip := range []string{"1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9"} {
			t, _ := parseCheckTarget(ip, "PING:"+ip)
			targets = append(targets, t)
		}
	}
	if len(targets) > 128 {
		return nil, fmt.Errorf("Не более 128 целей")
	}
	return targets, nil
}
func (z *Zapret) dpiTargets(ctx context.Context) ([]checkTarget, error) {
	req, _ := http.NewRequestWithContext(ctx, "GET", "https://hyperion-cs.github.io/dpi-checkers/ru/tcp-16-20/suite.v2.json", nil)
	client := subscriptionClient()
	client.Timeout = 15 * time.Second
	resp, e := client.Do(req)
	if e != nil {
		return nil, e
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("DPI suite: HTTP %d", resp.StatusCode)
	}
	var suite []struct {
		ID       string `json:"id"`
		Host     string `json:"host"`
		Provider string `json:"provider"`
	}
	if e = json.NewDecoder(io.LimitReader(resp.Body, 256<<10)).Decode(&suite); e != nil {
		return nil, e
	}
	if len(suite) == 0 || len(suite) > 128 {
		return nil, fmt.Errorf("Некорректный размер DPI suite")
	}
	targets := []checkTarget{}
	for _, v := range suite {
		t, e := parseCheckTarget(v.ID+" · "+v.Provider, "https://"+v.Host)
		if e != nil {
			return nil, e
		}
		targets = append(targets, t)
	}
	return targets, nil
}
func (z *Zapret) checkNetwork(ctx context.Context, folder, kind string, strategies []string, sweep bool) (err error) {
	var targets []checkTarget
	if kind == "dpi" {
		z.message("Загружаем список DPI-checkers…")
		targets, err = z.dpiTargets(ctx)
	} else {
		targets, err = standardTargets(folder)
	}
	if err != nil {
		return err
	}
	groups := []string{"Текущая сеть"}
	if sweep {
		groups = strategies
	}
	n := 0
	for _, t := range targets {
		if t.PingOnly {
			n++
		} else {
			n += 3
			if kind == "standard" {
				n++
			}
		}
	}
	z.mu.Lock()
	z.job.Total = n * len(groups)
	previous, wasRunning := z.strategy, z.cmd != nil
	z.mu.Unlock()
	testFolder := folder
	if sweep {
		z.stopProcess()
		defer func() {
			z.stopProcess()
			if testFolder != folder {
				os.RemoveAll(testFolder)
			}
			if wasRunning {
				if e := z.start(folder, previous, true); e != nil {
					err = fmt.Errorf("Не удалось восстановить стратегию %s: %w", previous, e)
				}
			}
		}()
	}
	// DPI suite should cover all destination IPs without altering the user's lists.
	if sweep && kind == "dpi" {
		testFolder, err = makeZapretTestCopy(folder)
		if err != nil {
			return err
		}
	}
	for _, strategy := range groups {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if sweep {
			z.message("Запускаем " + strategy)
			if e := z.start(testFolder, strategy, true); e != nil {
				z.addResult(CheckResult{Strategy: strategy, Check: "Запуск", State: "error", Detail: e.Error()})
				continue
			}
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(800 * time.Millisecond):
			}
			if !z.running() {
				z.addResult(CheckResult{Strategy: strategy, Check: "Запуск", State: "error", Detail: "winws завершился"})
				continue
			}
		}
		z.message("Проверяем: " + strategy)
		jobs := make(chan func())
		var wg sync.WaitGroup
		for i := 0; i < 4; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for f := range jobs {
					if ctx.Err() == nil {
						f()
					}
				}
			}()
		}
		send := func(t checkTarget, protocol string) {
			jobs <- func() { r := runNetworkCheck(ctx, t, protocol, kind == "dpi"); r.Strategy = strategy; z.addResult(r) }
		}
		for _, t := range targets {
			if ctx.Err() != nil {
				break
			}
			if !t.PingOnly {
				for _, p := range []string{"HTTP/1.1", "TLS 1.2", "TLS 1.3"} {
					send(t, p)
				}
			}
			if t.PingOnly || kind == "standard" {
				send(t, "Ping")
			}
		}
		close(jobs)
		wg.Wait()
		if sweep {
			z.stopProcess()
		}
	}
	z.message("Проверка завершена. HTTP-ответ подтверждает соединение, но не доступность всех функций сервиса.")
	return ctx.Err()
}
func makeZapretTestCopy(folder string) (string, error) {
	dest, e := os.MkdirTemp("", "svoi-zapret-test-")
	if e != nil {
		return "", e
	}
	ok := false
	defer func() {
		if !ok {
			os.RemoveAll(dest)
		}
	}()
	var total int64
	e = filepath.WalkDir(folder, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("Ссылки в папке zapret не поддерживаются")
		}
		rel, e := filepath.Rel(folder, path)
		if e != nil {
			return e
		}
		target := filepath.Join(dest, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0700)
		}
		info, e := d.Info()
		if e != nil {
			return e
		}
		total += info.Size()
		if total > 256<<20 {
			return fmt.Errorf("Папка zapret слишком большая")
		}
		b, e := os.ReadFile(path)
		if e != nil {
			return e
		}
		return os.WriteFile(target, b, 0600)
	})
	if e != nil {
		return "", e
	}
	if e = os.WriteFile(filepath.Join(dest, "lists", "ipset-all.txt"), nil, 0600); e != nil {
		return "", e
	}
	ok = true
	return dest, nil
}
func runNetworkCheck(parent context.Context, t checkTarget, protocol string, dpi bool) CheckResult {
	r := CheckResult{Target: t.Name, Check: protocol, State: "error"}
	ctx, cancel := context.WithTimeout(parent, 6*time.Second)
	defer cancel()
	start := time.Now()
	if protocol == "Ping" {
		ips, e := net.DefaultResolver.LookupNetIP(ctx, "ip", t.Host)
		if e != nil || len(ips) == 0 {
			r.Detail = "Ошибка DNS"
			return r
		}
		for _, ip := range ips {
			if !publicIP(ip) {
				r.Detail = "Адрес не является публичным"
				return r
			}
		}
		detail, e := pingHost(ctx, ips[0].String())
		r.Millis = time.Since(start).Milliseconds()
		r.Detail = detail
		if e == nil {
			r.State = "ok"
		}
		return r
	}
	client := subscriptionClient()
	client.Timeout = 5 * time.Second
	tr := client.Transport.(*http.Transport)
	tr.DisableKeepAlives = true
	tr.ForceAttemptHTTP2 = false
	tr.TLSHandshakeTimeout = 3 * time.Second
	tr.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	if protocol == "TLS 1.2" {
		tr.TLSClientConfig.MaxVersion = tls.VersionTLS12
	}
	if protocol == "TLS 1.3" {
		tr.TLSClientConfig.MinVersion = tls.VersionTLS13
		tr.TLSClientConfig.MaxVersion = tls.VersionTLS13
	}
	defer tr.CloseIdleConnections()
	method := "HEAD"
	var body io.Reader
	if dpi {
		payload := make([]byte, 65536)
		if _, e := rand.Read(payload); e != nil {
			r.Detail = e.Error()
			return r
		}
		body = bytes.NewReader(payload)
		method = "POST"
	}
	req, e := http.NewRequestWithContext(ctx, method, t.URL, body)
	if e != nil {
		r.Detail = e.Error()
		return r
	}
	if dpi {
		req.Header.Set("Range", "bytes=0-65535")
	}
	req.Header.Set("User-Agent", "SVOI-check/"+appVersion)
	var sent atomic.Bool
	req = req.WithContext(httptrace.WithClientTrace(req.Context(), &httptrace.ClientTrace{WroteRequest: func(i httptrace.WroteRequestInfo) { sent.Store(i.Err == nil) }}))
	response, e := client.Do(req)
	var downloaded int64
	if response != nil {
		if dpi {
			downloaded, e = io.Copy(io.Discard, io.LimitReader(response.Body, 65536))
		}
		response.Body.Close()
		r.Detail = fmt.Sprintf("HTTP %d", response.StatusCode)
		if dpi {
			r.Detail += fmt.Sprintf(" · принято %d Б", downloaded)
		}
	}
	r.Millis = time.Since(start).Milliseconds()
	if e == nil {
		r.State = "ok"
		return r
	}
	r.Detail = e.Error()
	var dns *net.DNSError
	var cert *tls.CertificateVerificationError
	var unknown x509.UnknownAuthorityError
	var ne net.Error
	switch {
	case errors.As(e, &dns):
		r.State = "dns"
	case errors.As(e, &cert) || errors.As(e, &unknown):
		r.State = "tls"
	case dpi && sent.Load() && downloaded == 0 && errors.As(e, &ne) && ne.Timeout():
		r.State = "suspected"
		r.Detail = "Таймаут после отправки 64 КБ; возможная фильтрация, не доказательство DPI"
	case strings.Contains(strings.ToLower(e.Error()), "protocol version"):
		r.State = "unsupported"
	}
	return r
}
func (z *Zapret) diagnostics(ctx context.Context, folder string) error {
	z.message("Проверяем Windows, службы, DNS и конфликты…")
	results, e := systemZapretDiagnostics(ctx, folder)
	if e != nil {
		return e
	}
	z.mu.Lock()
	z.job.Total = len(results)
	z.mu.Unlock()
	for _, r := range results {
		z.addResult(r)
	}
	z.message("Диагностика завершена. Настройки Windows и сторонние службы не изменены.")
	return nil
}
