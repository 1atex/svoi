package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"
)

type dnsAdapter struct {
	Index   int      `json:"index"`
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Servers []string `json:"servers"`
	Static  []string `json:"static"`
}
type dnsCandidate struct {
	Name    string `json:"name"`
	Address string `json:"address"`
}
type dnsResult struct {
	Address   string    `json:"address"`
	MedianMS  float64   `json:"medianMs"`
	WorstMS   float64   `json:"worstMs"`
	Success   int       `json:"success"`
	Total     int       `json:"total"`
	Route     string    `json:"route"`
	CheckedAt time.Time `json:"checkedAt"`
}

var publicDNS = func() []dnsCandidate {
	data, err := assets.ReadFile("web/dns-providers.json")
	var candidates []dnsCandidate
	if err != nil || json.Unmarshal(data, &candidates) != nil || len(candidates) == 0 {
		panic("invalid embedded DNS catalog")
	}
	return candidates
}()
var dnsProbeSlots = make(chan struct{}, 3)

type dnsHost interface {
	adapters(context.Context) ([]dnsAdapter, error)
	set(context.Context, int, []string) error
	elevated() bool
}
type nativeDNSHost struct{}

func (nativeDNSHost) adapters(ctx context.Context) ([]dnsAdapter, error) {
	return systemDNSAdapters(ctx)
}
func (nativeDNSHost) set(ctx context.Context, index int, addresses []string) error {
	return setSystemDNS(ctx, index, addresses)
}
func (nativeDNSHost) elevated() bool { return isElevated() }

func (a *App) dnsConnectionKey() string {
	if a.engine == nil {
		return ""
	}
	s := a.engine.snapshot(false)
	return fmt.Sprint(s.State, s.Mode, s.ServerID, s.StartedAt)
}

func measureDNS(ctx context.Context, address, route string, lookup func(context.Context, string) error) (dnsResult, error) {
	result := dnsResult{Address: address, Route: route, CheckedAt: time.Now().UTC()}
	var samples []float64
	for _, name := range []string{"example.com", "www.microsoft.com", "www.wikipedia.org", "example.com", "www.microsoft.com", "www.wikipedia.org"} {
		if err := ctx.Err(); err != nil {
			return result, err
		}
		query, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
		start := time.Now()
		err := lookup(query, name)
		elapsed := float64(time.Since(start).Microseconds()) / 1000
		cancel()
		result.Total++
		if err == nil {
			result.Success++
			samples = append(samples, elapsed)
		}
	}
	if err := ctx.Err(); err != nil {
		return result, err
	}
	sort.Float64s(samples)
	if n := len(samples); n > 0 {
		result.MedianMS = samples[n/2]
		if n%2 == 0 {
			result.MedianMS = (samples[n/2-1] + samples[n/2]) / 2
		}
		result.WorstMS = samples[n-1]
	}
	return result, nil
}

func (a *App) dnsRoute() string {
	if a.engine != nil {
		s := a.engine.snapshot(false)
		if s.State == "running" {
			if s.Mode == "tun" {
				return "TUN · по правилам маршрутизации профиля"
			}
			return "Напрямую · системный/локальный прокси не используется"
		}
	}
	return "Напрямую · VPN выключен"
}

func (a *App) dnsAPI(w http.ResponseWriter, r *http.Request) error {
	if r.Method == "GET" && r.URL.Path == "/api/dns/catalog" {
		writeJSON(w, 200, map[string]any{"candidates": publicDNS})
		return nil
	}
	if r.Method == "POST" && r.URL.Path == "/api/dns/benchmark" {
		var in struct {
			Address string `json:"address"`
		}
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&in) != nil || net.ParseIP(in.Address) == nil {
			return fail(400, "Некорректный адрес DNS")
		}
		select {
		case dnsProbeSlots <- struct{}{}:
			defer func() { <-dnsProbeSlots }()
		default:
			return fail(429, "Уже выполняются три проверки DNS")
		}
		route := a.dnsRoute()
		connectionKey := a.dnsConnectionKey()
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		defer cancel()
		resolver := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, net.JoinHostPort(in.Address, "53"))
		}}
		result, err := measureDNS(ctx, in.Address, route, func(ctx context.Context, name string) error {
			ips, err := resolver.LookupIP(ctx, "ip4", name)
			if err == nil && len(ips) == 0 {
				return fmt.Errorf("Пустой ответ DNS")
			}
			return err
		})
		if err != nil {
			return err
		}
		if connectionKey != a.dnsConnectionKey() {
			return fail(409, "Режим VPN изменился во время проверки. Повторите тест.")
		}
		writeJSON(w, 200, result)
		return nil
	}
	if r.Method != "GET" {
		a.networkOp.Lock()
		defer a.networkOp.Unlock()
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	host := a.dnsHost
	if host == nil {
		host = nativeDNSHost{}
	}
	adapters, err := host.adapters(ctx)
	if err != nil {
		return err
	}
	backupPath := a.path + ".dns-backup.json"
	var backup *dnsAdapter
	if data, e := os.ReadFile(backupPath); e == nil {
		if err = json.Unmarshal(data, &backup); err != nil {
			return fmt.Errorf("Не удалось прочитать прежние DNS-настройки: %w", err)
		}
	} else if !os.IsNotExist(e) {
		return e
	}
	if r.Method == "GET" && r.URL.Path == "/api/dns" {
		writeJSON(w, 200, map[string]any{"adapters": adapters, "candidates": publicDNS, "backup": backup, "route": a.dnsRoute(), "elevated": host.elevated()})
		return nil
	}
	if r.Method != "POST" || (r.URL.Path != "/api/dns/apply" && r.URL.Path != "/api/dns/restore") {
		return fail(404, "Метод DNS не найден")
	}
	if !host.elevated() {
		return fail(409, "Для изменения DNS нужны права администратора")
	}
	if a.engine != nil && a.engine.snapshot(false).State != "stopped" {
		return fail(409, "Отключите VPN перед изменением DNS Windows")
	}
	if r.URL.Path == "/api/dns/restore" {
		if backup == nil {
			return fail(409, "Нет сохранённых настроек DNS")
		}
		for _, adapter := range adapters {
			if adapter.ID == backup.ID {
				if err = host.set(ctx, adapter.Index, backup.Static); err != nil {
					return err
				}
				if err = os.Remove(backupPath); err != nil {
					return err
				}
				writeJSON(w, 200, map[string]any{"restored": true})
				return nil
			}
		}
		return fail(409, "Прежний сетевой адаптер недоступен. Подключите его и повторите восстановление.")
	}
	var in struct {
		ID      string `json:"id"`
		Address string `json:"address"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 2048)).Decode(&in) != nil {
		return fail(400, "Некорректный запрос DNS")
	}
	allowed := false
	for _, c := range publicDNS {
		if c.Address == in.Address {
			allowed = true
		}
	}
	if !allowed {
		return fail(400, "Выберите DNS из списка проверяемых провайдеров")
	}
	for _, adapter := range adapters {
		if adapter.ID != in.ID {
			continue
		}
		if backup != nil && backup.ID != adapter.ID {
			return fail(409, "Сначала восстановите DNS предыдущего адаптера")
		}
		if backup == nil {
			data, _ := json.Marshal(adapter)
			if err = os.WriteFile(backupPath+".tmp", data, 0600); err != nil {
				return err
			}
			if err = os.Rename(backupPath+".tmp", backupPath); err != nil {
				return err
			}
		}
		if err = host.set(ctx, adapter.Index, []string{in.Address}); err != nil {
			return fmt.Errorf("Не удалось применить DNS: %w. Прежние настройки сохранены; используйте «Восстановить DNS»", err)
		}
		writeJSON(w, 200, map[string]any{"applied": true})
		return nil
	}
	return fail(404, "Адаптер больше не доступен; обновите список")
}

func dnsStaticAddresses(value string) []string {
	result := []string{}
	for _, s := range strings.FieldsFunc(value, func(r rune) bool { return r == ',' || r == ';' || r == ' ' }) {
		if ip := net.ParseIP(s); ip != nil && ip.To4() != nil {
			result = append(result, s)
		}
	}
	return result
}
