package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

type islandPeer struct {
	Path string `json:"path"`
	Hash string `json:"hash"`
	User string `json:"user"`
}

type islandContext struct {
	Revision      uint64   `json:"revision"`
	Selected      string   `json:"selected"`
	Mode          string   `json:"mode"`
	Favorites     []string `json:"favorites"`
	Servers       []string `json:"servers"`
	Authorization string   `json:"-"`
}

type islandBridge struct {
	sequence     uint64
	instance     int64
	mu           sync.Mutex
	op           sync.Mutex
	grant        islandPeer
	pending      islandPeer
	pendingAt    time.Time
	view         islandContext
	revision     uint64
	closeClients func()
}

var startIslandTransport = func(*App) (func(), error) { return func() {}, nil }
var sealIslandGrant = func(b []byte) ([]byte, error) { return b, nil }
var openIslandGrant = func(b []byte) ([]byte, error) { return b, nil }

func (a *App) island() *islandBridge {
	a.islandOnce.Do(func() {
		a.islandBridge = &islandBridge{instance: time.Now().UnixNano()}
		if raw, err := os.ReadFile(a.path + ".night-island"); err == nil {
			if raw, err = openIslandGrant(raw); err == nil {
				_ = json.Unmarshal(raw, &a.islandBridge.grant)
			}
		}
	})
	return a.islandBridge
}

func (a *App) islandAPI(w http.ResponseWriter, r *http.Request) error {
	b := a.island()
	switch {
	case r.Method == "GET" && r.URL.Path == "/api/night-island":
		b.mu.Lock()
		defer b.mu.Unlock()
		path := b.pending.Path
		if b.grant.Path != "" {
			path = b.grant.Path
		}
		writeJSON(w, 200, map[string]any{"enabled": b.grant.Path != "", "clientPath": path, "candidate": b.pending.Hash, "available": time.Since(b.pendingAt) < 10*time.Second, "clientChanged": b.grant.Path != "" && b.pending.Path != "" && b.grant != b.pending})
	case r.Method == "PUT" && r.URL.Path == "/api/night-island":
		var in struct {
			Enabled   bool   `json:"enabled"`
			Candidate string `json:"candidate"`
		}
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&in) != nil {
			return fail(400, "Некорректное разрешение")
		}
		b.mu.Lock()
		defer b.mu.Unlock()
		if !in.Enabled {
			b.grant = islandPeer{}
			b.revision++
			if b.closeClients != nil {
				b.closeClients()
			}
			if err := os.Remove(a.path + ".night-island"); err != nil && !os.IsNotExist(err) {
				return err
			}
		} else {
			if b.pending.Path == "" || time.Since(b.pendingAt) > 10*time.Second || in.Candidate != b.pending.Hash {
				return fail(409, "Откройте Night Island и выберите SVOI в «Настройки → Интеграции → VPN», затем повторите.")
			}
			raw, err := json.Marshal(b.pending)
			if err != nil {
				return err
			}
			raw, err = sealIslandGrant(raw)
			if err != nil {
				return err
			}
			if err = os.WriteFile(a.path+".night-island", raw, 0600); err != nil {
				return err
			}
			b.grant = b.pending
			b.revision++
		}
		writeJSON(w, 200, map[string]any{"enabled": b.grant.Path != ""})
	case r.Method == "POST" && r.URL.Path == "/api/night-island/context":
		var in islandContext
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 65536)).Decode(&in) != nil || len(in.Favorites) > 512 || len(in.Servers) > 4096 {
			return fail(400, "Некорректный список серверов")
		}
		if in.Mode != "tun" && in.Mode != "system" && in.Mode != "local" {
			return fail(400, "Некорректный режим")
		}
		in.Authorization = r.Header.Get("Authorization")
		b.mu.Lock()
		if in.Revision >= b.view.Revision {
			if b.view.Authorization != in.Authorization || b.view.Mode != in.Mode {
				b.revision++
			}
			b.view = in
		}
		b.mu.Unlock()
		writeJSON(w, 200, map[string]bool{"ok": true})
	default:
		return fail(404, "Интеграция не найдена")
	}
	return nil
}

type islandServer struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Protocol string `json:"protocol"`
}

type islandState struct {
	Sequence  uint64         `json:"sequence"`
	Instance  int64          `json:"instance"`
	Version   int            `json:"version"`
	Access    string         `json:"access"`
	State     string         `json:"state,omitempty"`
	Active    *islandServer  `json:"active,omitempty"`
	Selected  *islandServer  `json:"selected,omitempty"`
	Favorites []islandServer `json:"favorites,omitempty"`
	Mode      string         `json:"mode,omitempty"`
	Core      string         `json:"core,omitempty"`
	Verified  bool           `json:"verified"`
	Latency   *int64         `json:"latency,omitempty"`
	StartedAt *time.Time     `json:"startedAt,omitempty"`
	Busy      bool           `json:"busy"`
	Error     string         `json:"error,omitempty"`
}

func (b *islandBridge) allowed(peer islandPeer) bool {
	return b.grant.Path != "" && b.grant == peer
}

func islandName(s string) string {
	s = strings.Map(func(r rune) rune {
		if r < 32 || r == 127 {
			return -1
		}
		return r
	}, s)
	r := []rune(s)
	if len(r) > 100 {
		r = r[:100]
	}
	return string(r)
}

func (a *App) islandSnapshot(peer islandPeer) islandState {
	b := a.island()
	b.mu.Lock()
	if !b.allowed(peer) {
		result := b.deniedLocked()
		b.mu.Unlock()
		return result
	}
	v := b.view
	b.sequence++
	sequence, instance := b.sequence, b.instance
	b.mu.Unlock()
	s := islandState{Version: 1, Access: "allowed", State: "stopped", Sequence: sequence, Instance: instance}
	if a.engine == nil {
		return s
	}
	status := a.engine.snapshot(false)
	s.State, s.Core, s.Mode = status.State, status.Core, v.Mode
	s.Busy = status.State == "starting" || status.State == "stopping"
	request, _ := http.NewRequest("GET", "http://127.0.0.1/api/me", nil)
	request.Header.Set("Authorization", v.Authorization)
	a.mu.Lock()
	g, _, err := a.auth(request)
	if err != nil {
		a.mu.Unlock()
		s.Error = "Откройте профиль в SVOI"
		return s
	}
	all := groupServerViews(g)
	a.mu.Unlock()
	visible := map[string]bool{}
	for _, id := range v.Servers {
		visible[id] = true
	}
	favorites := map[string]bool{}
	for _, id := range v.Favorites {
		favorites[id] = true
	}
	for _, server := range all {
		entry := islandServer{ID: server.ID, Name: islandName(server.Name), Protocol: server.Protocol}
		if server.ID == v.Selected && visible[server.ID] {
			copy := entry
			s.Selected = &copy
		}
		if status.State == "running" && server.ID == status.ServerID {
			copy := entry
			s.Active = &copy
		}
		if visible[server.ID] && favorites[server.ID] && len(s.Favorites) < 64 {
			s.Favorites = append(s.Favorites, entry)
		}
	}
	if status.State == "running" {
		s.Mode = status.Mode
		s.Verified = status.Checked && status.Error == ""
		s.StartedAt = status.StartedAt
		if s.Verified && status.CheckedAt != nil && status.Latency >= 0 {
			value := status.Latency
			s.Latency = &value
		}
		if status.Error != "" {
			s.Error = "VPN включён, но интернет не подтверждён. Откройте диагностику SVOI."
		}
	} else if status.State == "error" {
		s.Error = "Не удалось подключиться. Откройте диагностику SVOI."
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.allowed(peer) {
		return b.deniedLocked()
	}
	return s
}

func (a *App) islandCommand(ctx context.Context, peer islandPeer, action, id string) islandState {
	b := a.island()
	if action == "state" || action == "favorites" {
		return a.islandSnapshot(peer)
	}
	if !b.op.TryLock() {
		s := a.islandSnapshot(peer)
		s.Busy = true
		return s
	}
	defer b.op.Unlock()
	b.mu.Lock()
	if !b.allowed(peer) {
		result := b.deniedLocked()
		b.mu.Unlock()
		return result
	}
	v, revision := b.view, b.revision
	b.mu.Unlock()
	path := "/api/connection/start"
	if action == "disconnect" {
		path = "/api/connection/stop"
	} else if action != "connect" && action != "switch" {
		s := a.islandSnapshot(peer)
		s.Error = "Неизвестное действие"
		return s
	}
	if id == "" {
		id = v.Selected
	}
	s := a.islandSnapshot(peer)
	if s.Access != "allowed" {
		return s
	}
	if path == "/api/connection/start" {
		valid := false
		for _, value := range v.Servers {
			if value == id {
				valid = true
				break
			}
		}
		if !valid || id == "" {
			s.Error = "Выберите доступный сервер в SVOI"
			return s
		}
		if s.Active != nil && s.Active.ID == id && s.Mode == v.Mode {
			return s
		}
	}
	b.mu.Lock()
	valid := b.allowed(peer) && b.revision == revision
	b.mu.Unlock()
	if !valid {
		return islandState{Version: 1, Access: "denied"}
	}
	body, _ := json.Marshal(map[string]any{"serverId": id, "mode": v.Mode})
	r, _ := http.NewRequestWithContext(ctx, "POST", "http://127.0.0.1"+path, bytes.NewReader(body))
	r.RemoteAddr = "127.0.0.1:1"
	r.Header.Set("Authorization", v.Authorization)
	writer := &islandWriter{header: http.Header{}}
	r = r.WithContext(context.WithValue(r.Context(), islandAccessKey{}, islandAccess{peer: peer, revision: revision}))
	err := a.engineAPI(writer, r)
	if err == nil && path == "/api/connection/start" {
		b.mu.Lock()
		if b.revision == revision {
			b.view.Selected = id
		}
		b.mu.Unlock()
		_, err = a.engine.Check(ctx)
	}
	s = a.islandSnapshot(peer)
	if err != nil && s.Access == "allowed" {
		s.Error = "Подключение не подтверждено. Проверьте состояние и диагностику в SVOI."
	}
	return s
}

type islandWriter struct{ header http.Header }

func (w *islandWriter) Header() http.Header       { return w.header }
func (*islandWriter) WriteHeader(int)             {}
func (*islandWriter) Write(p []byte) (int, error) { return len(p), nil }

type islandAccessKey struct{}
type islandAccess struct {
	peer     islandPeer
	revision uint64
}

func (a *App) checkIslandAccess(ctx context.Context) error {
	if access, ok := ctx.Value(islandAccessKey{}).(islandAccess); ok {
		b := a.island()
		b.mu.Lock()
		defer b.mu.Unlock()
		if !b.allowed(access.peer) || b.revision != access.revision || ctx.Err() != nil {
			return fail(403, "Доступ Night Island отозван")
		}
	}
	return nil
}

func (b *islandBridge) deniedLocked() islandState {
	b.sequence++
	return islandState{Version: 1, Access: "denied", Instance: b.instance, Sequence: b.sequence}
}
