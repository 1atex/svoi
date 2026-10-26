package backend

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

var appVersion = "0.4.0-prebeta.3"
var nativeVersion = "0.5.0-beta.15"

//go:embed web/*
var assets embed.FS

type Identity struct {
	OmitDeviceHeaders bool   `json:"omitDeviceHeaders,omitempty"`
	HWID              string `json:"hwid"`
	OS                string `json:"os"`
	Model             string `json:"model"`
	Locale            string `json:"locale"`
	UserAgent         string `json:"userAgent"`
}
type Device struct {
	ID       string    `json:"id"`
	Name     string    `json:"name"`
	Platform string    `json:"platform"`
	Owner    bool      `json:"owner"`
	Joined   time.Time `json:"joined"`
}

type Member struct {
	Device    Device `json:"device"`
	TokenHash string `json:"tokenHash"`
}
type Invite struct {
	Hash    string    `json:"hash"`
	Expires time.Time `json:"expires"`
}
type Group struct {
	ID              string         `json:"id"`
	Name            string         `json:"name"`
	Identity        Identity       `json:"identity"`
	Devices         []Member       `json:"devices"`
	Invites         []Invite       `json:"invites"`
	SubscriptionURL string         `json:"subscriptionURL"`
	LastRefresh     *Report        `json:"lastRefresh,omitempty"`
	Servers         []ServerConfig `json:"servers,omitempty"`
	Subscriptions   []Subscription `json:"subscriptions,omitempty"`
}
type Report struct {
	Count     int       `json:"count"`
	Format    string    `json:"format"`
	FetchedAt time.Time `json:"fetchedAt"`
	Warnings  []string  `json:"warnings,omitempty"`
}
type State struct {
	Groups []Group `json:"groups"`
}
type App struct {
	mu         sync.Mutex
	state      State
	path       string
	client     *http.Client
	limits     map[string][]time.Time
	engine     *Engine
	probeSlots chan struct{}
	settingsMu sync.Mutex
	settings   LocalSettings
	updates    *Updater
	zapret     *Zapret
	networkOp  sync.Mutex
	handoff    vpnHandoff
	dnsHost    dnsHost
}
type input struct {
	Name       string   `json:"name"`
	DeviceName string   `json:"deviceName"`
	Platform   string   `json:"platform"`
	Invite     string   `json:"invite"`
	Identity   Identity `json:"identity"`
	URL        string   `json:"url"`
}
type apiError struct {
	status  int
	message string
}

func (e apiError) Error() string            { return e.message }
func fail(status int, message string) error { return apiError{status, message} }
func secret() string {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}
func digest(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }

func openApp(path string) (*App, error) {
	a := &App{path: path, client: subscriptionClient(), limits: map[string][]time.Time{}, probeSlots: make(chan struct{}, 10)}
	if err := a.loadSettings(); err != nil {
		return nil, err
	}
	b, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	if len(b) > 0 {
		if err = json.Unmarshal(b, &a.state); err != nil {
			return nil, fmt.Errorf("read group state: %w", err)
		}
	}
	for i := range a.state.Groups {
		migrateSubscriptions(&a.state.Groups[i])
	}
	return a, nil
}

func (a *App) transaction(fn func() error) error {
	before, _ := json.Marshal(a.state)
	rollback := func(err error) error { _ = json.Unmarshal(before, &a.state); return err }
	if err := fn(); err != nil {
		return rollback(err)
	}
	b, err := json.MarshalIndent(a.state, "", "  ")
	if err != nil {
		return rollback(err)
	}
	if err = os.MkdirAll(filepath.Dir(a.path), 0700); err != nil {
		return rollback(err)
	}
	tmp := a.path + ".tmp"
	if err = os.WriteFile(tmp, b, 0600); err != nil {
		return rollback(err)
	}
	if err = os.Rename(tmp, a.path); err != nil {
		return rollback(err)
	}
	return nil
}
func decode(w http.ResponseWriter, r *http.Request) (input, error) {
	var in input
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192))
	d.DisallowUnknownFields()
	if err := d.Decode(&in); err != nil {
		return in, fail(400, "Некорректный запрос")
	}
	if err := d.Decode(&struct{}{}); err != io.EOF {
		return in, fail(400, "Лишние данные в запросе")
	}
	return in, nil
}
func validText(s string, max int) bool {
	return strings.TrimSpace(s) != "" && len([]rune(s)) <= max && !strings.ContainsAny(s, "\r\n\x00")
}
func validIdentity(i Identity) bool {
	for _, s := range []string{i.HWID, i.OS, i.Model, i.Locale, i.UserAgent} {
		if !validText(s, 180) {
			return false
		}
		for _, r := range s {
			if r < 32 || r > 126 {
				return false
			}
		}
	}
	return true
}
func (a *App) auth(r *http.Request) (*Group, *Member, error) {
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if len(token) != 32 {
		return nil, nil, fail(401, "Войдите в группу заново")
	}
	h := digest(token)
	for gi := range a.state.Groups {
		g := &a.state.Groups[gi]
		for di := range g.Devices {
			d := &g.Devices[di]
			if d.TokenHash == h {
				return g, d, nil
			}
		}
	}
	return nil, nil, fail(401, "Устройство больше не состоит в группе")
}
func snapshot(g *Group, d *Member) map[string]any {
	migrateSubscriptions(g)
	devices := make([]Device, 0, len(g.Devices))
	for _, m := range g.Devices {
		devices = append(devices, m.Device)
	}
	host := ""
	if u, err := url.Parse(g.SubscriptionURL); err == nil {
		host = u.Hostname()
	}
	servers := make([]ServerInfo, 0, len(g.Servers))
	for _, server := range g.Servers {
		servers = append(servers, server.ServerInfo)
	}
	return map[string]any{"id": g.ID, "name": g.Name, "identity": g.Identity, "devices": devices, "self": d.Device.ID, "owner": d.Device.Owner, "subscriptionHost": host, "lastRefresh": g.LastRefresh, "servers": servers, "subscriptions": publicSubscriptions(g)}
}
func (a *App) limited(r *http.Request) bool {
	return a.limitedBucket(r, "general", 20)
}
func (a *App) limitedBucket(r *http.Request, bucket string, limit int) bool {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	host = bucket + ":" + host
	now := time.Now()
	times := a.limits[host]
	kept := times[:0]
	for _, t := range times {
		if now.Sub(t) < time.Minute {
			kept = append(kept, t)
		}
	}
	if len(a.limits) > 10000 {
		a.limits = map[string][]time.Time{}
	}
	a.limits[host] = append(kept, now)
	return len(kept) >= limit
}
func (a *App) api(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if err := a.dispatch(w, r); err != nil {
		status := 500
		message := "Не удалось сохранить изменения. Попробуйте ещё раз."
		var ae apiError
		if errors.As(err, &ae) {
			status = ae.status
			message = ae.message
		}
		writeJSON(w, status, map[string]string{"error": message})
	}
}
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func (a *App) dispatch(w http.ResponseWriter, r *http.Request) error {
	if r.URL.Path == "/api/settings" || r.URL.Path == "/api/startup" || strings.HasPrefix(r.URL.Path, "/api/updates") || strings.HasPrefix(r.URL.Path, "/api/zapret") || strings.HasPrefix(r.URL.Path, "/api/dns") {
		return a.desktopAPI(w, r)
	}
	if strings.HasPrefix(r.URL.Path, "/api/transfer/") {
		return a.transferAPI(w, r)
	}
	if strings.HasPrefix(r.URL.Path, "/api/servers/") && (strings.HasSuffix(r.URL.Path, "/config") || strings.HasSuffix(r.URL.Path, "/probe")) {
		return a.serverToolsAPI(w, r)
	}
	if r.Method == "GET" && r.URL.Path == "/api/health" {
		writeJSON(w, 200, map[string]string{"service": "svoi", "status": "ok", "version": appVersion})
		return nil
	}
	if r.URL.Path == "/api/subscription/refresh" && r.Method == "POST" || r.URL.Path == "/api/subscription/export" && r.Method == "GET" {
		return a.fetch(w, r)
	}
	if strings.HasPrefix(r.URL.Path, "/api/connection") {
		return a.engineAPI(w, r)
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if r.Method == "POST" && (r.URL.Path == "/api/groups" || r.URL.Path == "/api/join") {
		if a.limited(r) {
			return fail(429, "Слишком много попыток. Подождите минуту.")
		}
		in, err := decode(w, r)
		if err != nil {
			return err
		}
		if !validText(in.DeviceName, 60) || !validText(in.Platform, 32) {
			return fail(400, "Укажите имя устройства и платформу")
		}
		token := secret()
		member := Member{Device: Device{ID: secret(), Name: strings.TrimSpace(in.DeviceName), Platform: in.Platform, Joined: time.Now().UTC()}, TokenHash: digest(token)}
		var result map[string]any
		err = a.transaction(func() error {
			if r.URL.Path == "/api/groups" {
				if !validText(in.Name, 60) {
					return fail(400, "Введите название группы (до 60 символов)")
				}
				if len(a.state.Groups) >= 1000 {
					return fail(409, "Лимит групп на этом сервере достигнут")
				}
				member.Device.Owner = true
				identityOS := "Windows"
				if in.Platform == "Android" {
					identityOS = "Android"
				}
				g := Group{ID: secret(), Name: strings.TrimSpace(in.Name), Identity: Identity{HWID: digest(secret())[:32], OS: identityOS, Model: "SVOI Group", Locale: "ru-RU", UserAgent: "SVOI/0.2"}, Devices: []Member{member}}
				a.state.Groups = append(a.state.Groups, g)
				result = snapshot(&g, &member)
			} else {
				found := false
				h := digest(strings.TrimSpace(in.Invite))
				for gi := range a.state.Groups {
					g := &a.state.Groups[gi]
					for ii, inv := range g.Invites {
						if inv.Hash != h || !time.Now().Before(inv.Expires) {
							continue
						}
						if len(g.Devices) >= 32 {
							return fail(409, "В группе уже 32 устройства")
						}
						g.Invites = append(g.Invites[:ii], g.Invites[ii+1:]...)
						g.Devices = append(g.Devices, member)
						result = snapshot(g, &member)
						found = true
						break
					}
					if found {
						break
					}
				}
				if !found {
					return fail(400, "Инвайт недействителен, использован или истёк")
				}
			}
			return nil
		})
		if err != nil {
			return err
		}
		writeJSON(w, 201, map[string]any{"token": token, "group": result})
		return nil
	}
	g, d, err := a.auth(r)
	if err != nil {
		return err
	}
	if r.URL.Path == "/api/me" && r.Method == "GET" {
		writeJSON(w, 200, snapshot(g, d))
		return nil
	}
	if strings.HasPrefix(r.URL.Path, "/api/servers/") && strings.HasSuffix(r.URL.Path, "/export") && r.Method == "GET" {
		id := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/api/servers/"), "/export")
		for _, server := range g.Servers {
			if server.ID == id {
				config, err := buildXrayConfig(server, 10808, 10809, "local")
				if err != nil {
					return err
				}
				w.Header().Set("Content-Type", "application/json")
				w.Header().Set("Content-Disposition", `attachment; filename="svoi-xray.json"`)
				_, err = w.Write(config)
				return err
			}
		}
		return fail(404, "Сервер не найден")
	}
	if r.URL.Path == "/api/leave" && r.Method == "POST" {
		if d.Device.Owner {
			return fail(409, "Владелец не может покинуть группу")
		}
		id := d.Device.ID
		err = a.transaction(func() error {
			for i, m := range g.Devices {
				if m.Device.ID == id {
					g.Devices = append(g.Devices[:i], g.Devices[i+1:]...)
					break
				}
			}
			return nil
		})
		if err != nil {
			return err
		}
		writeJSON(w, 200, map[string]bool{"ok": true})
		return nil
	}
	if !d.Device.Owner {
		return fail(403, "Это действие доступно владельцу группы")
	}
	if r.URL.Path == "/api/subscriptions" || strings.HasPrefix(r.URL.Path, "/api/subscriptions/") {
		return a.subscriptionsAPI(w, r, g, d)
	}
	if r.URL.Path == "/api/subscription/import" && r.Method == "POST" {
		var in struct {
			Content string `json:"content"`
		}
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 6<<20)).Decode(&in) != nil {
			return fail(400, "Не удалось прочитать импорт")
		}
		if len(in.Content) > 4<<20 {
			return fail(413, "Конфигурация превышает 4 МБ")
		}
		parsed, err := parseSubscription([]byte(in.Content))
		if err != nil {
			return err
		}
		report := Report{Count: len(parsed.Servers), Format: parsed.Format, FetchedAt: time.Now().UTC(), Warnings: parsed.Warnings}
		migrateSubscriptions(g)
		if len(g.Subscriptions) >= 32 {
			return fail(409, "В группе уже 32 источника")
		}
		if err = a.transaction(func() error {
			g.Subscriptions = append(g.Subscriptions, Subscription{ID: secret(), Name: fmt.Sprintf("Импорт %d", len(g.Subscriptions)+1), Metadata: parseSubscriptionMetadata(parsed.MetadataHeaders)})
			replaceSubscriptionServers(g, &g.Subscriptions[len(g.Subscriptions)-1], parsed.Servers, &report)
			return nil
		}); err != nil {
			return err
		}
		writeJSON(w, 200, snapshot(g, d))
		return nil
	}
	if r.URL.Path == "/api/invites" && r.Method == "POST" {
		code := secret()
		expires := time.Now().UTC().Add(15 * time.Minute)
		err = a.transaction(func() error {
			live := []Invite{}
			for _, i := range g.Invites {
				if time.Now().Before(i.Expires) {
					live = append(live, i)
				}
			}
			if len(live) >= 20 {
				return fail(409, "Уже создано 20 активных инвайтов")
			}
			g.Invites = append(live, Invite{digest(code), expires})
			return nil
		})
		if err != nil {
			return err
		}
		writeJSON(w, 201, map[string]any{"code": code, "expires": expires})
		return nil
	}
	if strings.HasPrefix(r.URL.Path, "/api/devices/") && r.Method == "DELETE" {
		id := strings.TrimPrefix(r.URL.Path, "/api/devices/")
		if id == d.Device.ID {
			return fail(409, "Нельзя удалить владельца группы")
		}
		err = a.transaction(func() error {
			for i, m := range g.Devices {
				if m.Device.ID == id {
					g.Devices = append(g.Devices[:i], g.Devices[i+1:]...)
					return nil
				}
			}
			return fail(404, "Устройство не найдено")
		})
		if err != nil {
			return err
		}
		writeJSON(w, 200, snapshot(g, d))
		return nil
	}
	if r.URL.Path == "/api/identity" && r.Method == "PUT" {
		in, err := decode(w, r)
		if err != nil {
			return err
		}
		if !validIdentity(in.Identity) {
			return fail(400, "Все поля обязательны: до 180 печатных ASCII-символов")
		}
		err = a.transaction(func() error { g.Identity = in.Identity; g.LastRefresh = nil; return nil })
		if err != nil {
			return err
		}
		writeJSON(w, 200, snapshot(g, d))
		return nil
	}
	if r.URL.Path == "/api/subscription" && r.Method == "PUT" {
		in, err := decode(w, r)
		if err != nil {
			return err
		}
		if _, err = subscriptionURL(in.URL); err != nil {
			return err
		}
		migrateSubscriptions(g)
		err = a.transaction(func() error {
			s := subscriptionByID(g, "")
			if s == nil {
				g.Subscriptions = append(g.Subscriptions, Subscription{ID: "legacy", Name: "Подписка"})
				s = &g.Subscriptions[0]
			}
			s.URL = in.URL
			replaceSubscriptionServers(g, s, nil, nil)
			return nil
		})
		if err != nil {
			return err
		}
		writeJSON(w, 200, snapshot(g, d))
		return nil
	}
	return fail(404, "Метод API не найден")
}

func subscriptionURL(raw string) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Fragment != "" || (u.Port() != "" && u.Port() != "443") {
		return nil, fail(400, "Нужна HTTPS-ссылка подписки без логина и пароля, порт 443")
	}
	return u, nil
}

var blocked = []string{"0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/3", "::/96", "::ffff:0:0/96", "64:ff9b::/96", "64:ff9b:1::/48", "100::/64", "2001::/23", "2002::/16", "fc00::/7", "fe80::/10", "ff00::/8"}

func publicIP(ip netip.Addr) bool {
	ip = ip.Unmap()
	if !ip.IsGlobalUnicast() {
		return false
	}
	for _, s := range blocked {
		if netip.MustParsePrefix(s).Contains(ip) {
			return false
		}
	}
	return true
}
func subscriptionClient() *http.Client {
	dial := func(ctx context.Context, network, address string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(address)
		if err != nil {
			return nil, err
		}
		ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
		if err != nil {
			return nil, err
		}
		if len(ips) == 0 {
			return nil, errors.New("no addresses")
		}
		for _, ip := range ips {
			if !publicIP(ip) {
				return nil, errors.New("non-public subscription address")
			}
		}
		var last error
		for _, ip := range ips {
			c, e := (&net.Dialer{Timeout: 8 * time.Second}).DialContext(ctx, network, net.JoinHostPort(ip.String(), port))
			if e == nil {
				return c, nil
			}
			last = e
		}
		return nil, last
	}
	return &http.Client{Timeout: 20 * time.Second, Transport: &http.Transport{DialContext: dial, TLSHandshakeTimeout: 8 * time.Second, ResponseHeaderTimeout: 10 * time.Second, MaxIdleConns: 10, IdleConnTimeout: 30 * time.Second}, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}
}
func headers(i Identity) map[string]string {
	if i.OmitDeviceHeaders {
		return map[string]string{"User-Agent": i.UserAgent}
	}
	return map[string]string{"x-hwid": i.HWID, "x-device-os": i.OS, "x-device-model": i.Model, "x-device-locale": i.Locale, "User-Agent": i.UserAgent}
}
func inspectSubscription(b []byte) (Report, error) {
	parsed, err := parseSubscription(b)
	return Report{Count: len(parsed.Servers), Format: parsed.Format, FetchedAt: time.Now().UTC(), Warnings: parsed.Warnings}, err
}
func (a *App) fetch(w http.ResponseWriter, r *http.Request) error {
	a.mu.Lock()
	g, d, err := a.auth(r)
	if err != nil {
		a.mu.Unlock()
		return err
	}
	sub := subscriptionByID(g, r.URL.Query().Get("id"))
	if sub == nil {
		a.mu.Unlock()
		return fail(404, "Подписка не найдена")
	}
	raw := sub.URL
	sid := sub.ID
	identity := g.Identity
	gid := g.ID
	did := d.Device.ID
	if a.limitedBucket(r, "subscriptions", 64) {
		a.mu.Unlock()
		return fail(429, "Слишком много запросов. Подождите минуту.")
	}
	a.mu.Unlock()
	if raw == "" {
		return fail(400, "Сначала добавьте подписку")
	}
	u, err := subscriptionURL(raw)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(r.Context(), "GET", u.String(), nil)
	if err != nil {
		return err
	}
	for k, v := range headers(identity) {
		req.Header.Set(k, v)
	}
	req.Header.Set("Accept", "application/json, text/plain, */*")
	resp, err := a.client.Do(req)
	if err != nil {
		return fail(502, "Не удалось загрузить подписку. Проверьте адрес и доступность сервера.")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fail(502, fmt.Sprintf("Сервер подписки вернул HTTP %d. Перенаправления отключены.", resp.StatusCode))
	}
	const max = 4 << 20
	b, err := io.ReadAll(io.LimitReader(resp.Body, max+1))
	if err != nil {
		return fail(502, "Не удалось прочитать подписку")
	}
	if len(b) > max {
		return fail(413, "Подписка превышает 4 МБ")
	}
	parsed, err := parseSubscription(b)
	if err != nil {
		return err
	}
	report := Report{Count: len(parsed.Servers), Format: parsed.Format, FetchedAt: time.Now().UTC(), Warnings: parsed.Warnings}
	a.mu.Lock()
	defer a.mu.Unlock()

	g, d, err = a.auth(r)
	if err != nil {
		return err
	}
	sub = subscriptionByID(g, sid)
	if g.ID != gid || d.Device.ID != did || sub == nil || sub.URL != raw || g.Identity != identity {
		return fail(409, "Настройки группы изменились. Повторите запрос.")
	}
	metadata := mergeSubscriptionMetadata(parsed.MetadataHeaders, resp.Header)
	if err = a.transaction(func() error {
		sub.Metadata = metadata
		replaceSubscriptionServers(g, sub, parsed.Servers, &report)
		return nil
	}); err != nil {
		return err
	}
	if strings.HasSuffix(r.URL.Path, "/export") {
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Disposition", `attachment; filename="svoi-subscription.txt"`)
		_, err = w.Write(b)
		return err
	}
	writeJSON(w, 200, report)
	return nil
}
func (a *App) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/", a.api)
	sub, _ := fs.Sub(assets, "web")
	mux.Handle("/", http.FileServerFS(sub))
	protected := http.NewCrossOriginProtection().Handler(mux)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		protected.ServeHTTP(w, r)
	})
}

func existingInstance(address string) bool {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return false
	}
	ip, err := netip.ParseAddr(host)
	if err != nil || !ip.IsLoopback() {
		return false
	}
	client := &http.Client{Timeout: 2 * time.Second, Transport: &http.Transport{}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	defer client.CloseIdleConnections()
	resp, err := client.Get("http://" + net.JoinHostPort(host, port) + "/api/health")
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	var health struct {
		Service string `json:"service"`
		Status  string `json:"status"`
	}
	return resp.StatusCode == http.StatusOK && json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&health) == nil && health.Service == "svoi" && health.Status == "ok"
}

func run() error {
	listen := flag.String("listen", "127.0.0.1:8787", "HTTP listen address; use TLS reverse proxy for remote devices")
	data := flag.String("data", "", "state file (default: user config directory)")
	headless := flag.Bool("server", false, "Run only the group service, without a desktop window")
	native := flag.Bool("native-backend", false, "Private desktop backend; exit when parent stdin closes")
	flag.StringVar(&desktopExecutable, "desktop-exe", "", "Desktop executable for Windows startup")
	startup := flag.Bool("startup", false, "Start saved services after Windows logon")
	removeStartup := flag.Bool("remove-startup", false, "Remove the current user's startup task")
	startupStatus := flag.Bool("startup-status", false, "Check the current user's startup task for uninstall")
	watchParent := flag.Int("watch-parent", 0, "Internal proxy recovery helper")
	watchFile := flag.String("watch-proxy", "", "Internal proxy recovery snapshot")
	updateFile := flag.String("install-update", "", "Internal update installer")
	updateSHA := flag.String("update-sha256", "", "Internal installer checksum")
	updateParent := flag.Int("update-parent", 0, "Internal updater parent")
	flag.Parse()
	if *startupStatus {
		enabled, err := startupEnabled(desktopExecutable)
		if err != nil {
			return err
		}
		if !enabled {
			return errors.New("autostart is disabled")
		}
		return nil
	}
	if *removeStartup {
		return setStartup(desktopExecutable, false)
	}
	if *native {
		appVersion = nativeVersion
		releaseAssetPrefix = "SVOI"
		if *headless {
			return errors.New("native-backend and server are mutually exclusive")
		}
		if err := validateNativeAddress(*listen); err != nil {
			return err
		}
		if *data == "" {
			return errors.New("native backend requires a separate -data path")
		}
	}
	if *updateFile != "" {
		return installUpdateAfterExit(*updateFile, *updateSHA, *updateParent)
	}
	if *watchParent > 0 && *watchFile != "" {
		return watchProxy(*watchParent, *watchFile)
	}
	if *data == "" {
		dir, err := os.UserConfigDir()
		if err != nil {
			return err
		}
		*data = filepath.Join(dir, "SVOI", "groups.json")
	}
	listener, err := net.Listen("tcp", *listen)
	if err != nil {
		if !*native && existingInstance(*listen) {
			if desktopSupported && !*headless {
				return showDesktop("http://" + *listen)
			}
			fmt.Printf("SVOI уже запущен. Откройте http://%s в браузере.\nИспользуется ранее запущенный экземпляр и его файл данных.\n", *listen)
			return nil
		}
		return fmt.Errorf("не удалось запустить SVOI по адресу %s: %w", *listen, err)
	}
	defer listener.Close()
	a, err := openApp(*data)
	if err != nil {
		return err
	}
	if desktopSupported && (!*headless || *native) {
		exe, err := os.Executable()
		if err != nil {
			return err
		}
		a.engine, err = newEngine(filepath.Join(filepath.Dir(exe), "core", "xray.exe"), filepath.Join(filepath.Dir(*data), "runtime"))
		if err != nil {
			return err
		}
		defer a.engine.Stop()
		a.zapret = newZapret(a)
		defer a.zapret.Stop()
		if *native && *startup {
			if err := a.startSavedZapret(); err != nil {
				log.Print(err)
			}
		}
		if a.localSettings().ZapretAutoUpdate && a.zapret.installed.Directory != "" {
			a.zapret.launchJob("update", nil, false)
		}
		a.updates = newUpdater(a)
		if a.localSettings().AutoUpdate {
			a.updates.start("check")
		}
	}
	log.Printf("SVOI %s — http://%s", appVersion, *listen)
	server := &http.Server{Addr: *listen, Handler: a.handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 45 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16384}
	if *native {
		return serveNativeBackend(server, listener, os.Stdin, os.Stdout)
	}
	if desktopSupported && !*headless {
		go func() {
			if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
				log.Print(err)
			}
		}()
		err := showDesktop("http://" + *listen)
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
		return err
	}
	if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

func Main() {
	if err := run(); err != nil {
		if flag.Lookup("native-backend").Value.String() == "true" {
			log.Print(err)
		} else {
			showStartupError(err.Error())
		}
		os.Exit(1)
	}
}
