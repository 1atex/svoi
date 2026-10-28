package backend

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
)

type MobileApp struct {
	app     *App
	handler http.Handler
}

func OpenMobile(directory string) (*MobileApp, error) {
	a, err := openApp(filepath.Join(directory, "groups.json"))
	if err != nil {
		return nil, err
	}
	return &MobileApp{app: a, handler: a.handler()}, nil
}

func (m *MobileApp) Request(method, path, token, body string) string {
	return m.RequestContext(context.Background(), method, path, token, body)
}
func (m *MobileApp) RequestContext(ctx context.Context, method, path, token, body string) string {
	if !strings.HasPrefix(path, "/api/") || len(body) > 16*1024*1024 {
		return `{"status":400,"body":{"error":"Некорректный запрос"}}`
	}
	req := httptest.NewRequest(method, path, strings.NewReader(body)).WithContext(ctx)
	req.RemoteAddr = "127.0.0.1:1"
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	m.handler.ServeHTTP(w, req)
	var bodyJSON any
	if json.Unmarshal(w.Body.Bytes(), &bodyJSON) != nil {
		bodyJSON = map[string]string{"error": w.Body.String()}
	}
	data, _ := json.Marshal(map[string]any{"status": w.Code, "body": bodyJSON})
	return string(data)
}

func (m *MobileApp) TunnelConfig(token, serverID string) (string, error) {
	return m.serverConfig(token, serverID, "tun")
}

func (m *MobileApp) ProbeConfig(token, serverID string) (string, error) {
	return m.serverConfig(token, serverID, "local")
}

func (m *MobileApp) ProbeOptions() ProbeSettings {
	return m.app.localSettings().Probe
}

func (m *MobileApp) serverConfig(token, serverID, mode string) (string, error) {
	req := httptest.NewRequest("GET", "/api/me", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	m.app.mu.Lock()
	group, _, err := m.app.auth(req)
	var server ServerConfig
	found := false
	if err == nil {
		for _, item := range group.Servers {
			if item.ID == serverID {
				server = item
				found = true
				break
			}
		}
	}
	m.app.mu.Unlock()
	if err != nil {
		return "", err
	}
	if !found {
		return "", errors.New("сервер не найден")
	}
	server.RuntimeApps = nil
	raw, err := buildXrayConfig(server, 10808, 10809, mode)
	if err != nil {
		return "", err
	}
	var config object
	if err = json.Unmarshal(raw, &config); err != nil {
		return "", err
	}
	config["log"] = object{"loglevel": "warning", "access": "none"}
	for _, item := range config["inbounds"].([]any) {
		inbound := obj(item)
		if str(inbound["protocol"]) == "tun" {
			inbound["settings"] = object{"name": "SVOI", "mtu": 1500}
		}
	}
	raw, err = json.Marshal(config)
	return string(raw), err
}

func (m *MobileApp) SpeedConfig(token, serverID string) (string, error) {
	raw, err := m.ProbeConfig(token, serverID)
	if err != nil {
		return "", err
	}
	prepared, err := speedServerConfig(ServerConfig{Profile: json.RawMessage(raw)})
	return string(prepared.Profile), err
}

func (m *MobileApp) SpeedSelection(token string, ids []string) (string, []ServerInfo, error) {
	req := httptest.NewRequest("GET", "/api/me", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	m.app.mu.Lock()
	defer m.app.mu.Unlock()
	group, _, err := m.app.auth(req)
	if err != nil {
		return "", nil, err
	}
	if len(ids) > 3 {
		return "", nil, errors.New("Выберите до трёх серверов")
	}
	seen := map[string]bool{}
	selected := []ServerInfo{}
	for _, id := range ids {
		if seen[id] {
			return "", nil, errors.New("Сервер выбран дважды")
		}
		seen[id] = true
		found := false
		for _, s := range group.Servers {
			if s.ID == id {
				selected = append(selected, s.ServerInfo)
				found = true
				break
			}
		}
		if !found {
			return "", nil, errors.New("Список серверов изменился. Выберите их заново.")
		}
	}
	return group.ID, selected, nil
}
