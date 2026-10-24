package backend

import (
	"encoding/json"
	"errors"
	"net/http/httptest"
	"path/filepath"
	"strings"
)

type MobileApp struct{ app *App }

func OpenMobile(directory string) (*MobileApp, error) {
	a, err := openApp(filepath.Join(directory, "groups.json"))
	if err != nil {
		return nil, err
	}
	return &MobileApp{app: a}, nil
}

func (m *MobileApp) Request(method, path, token, body string) string {
	if !strings.HasPrefix(path, "/api/") || len(body) > 16*1024*1024 {
		return `{"status":400,"body":{"error":"Некорректный запрос"}}`
	}
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.RemoteAddr = "127.0.0.1:1"
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	m.app.handler().ServeHTTP(w, req)
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
	for _, item := range config["inbounds"].([]any) {
		inbound := obj(item)
		if str(inbound["protocol"]) == "tun" {
			inbound["settings"] = object{"name": "SVOI", "mtu": 1500}
		}
	}
	raw, err = json.Marshal(config)
	return string(raw), err
}
