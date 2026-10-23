package main

import (
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"
)

const transferLimit = 8 << 20
const transferCodeLimit = 12 << 20

// Explicit allowlist: local session tokens, invite hashes and device lists never travel.
type portableProfile struct {
	Version  int              `json:"version"`
	Name     string           `json:"name"`
	Identity Identity         `json:"identity"`
	Sources  []portableSource `json:"sources"`
}
type portableSource struct {
	Name      string           `json:"name"`
	URL       string           `json:"url,omitempty"`
	FetchedAt time.Time        `json:"fetchedAt,omitempty"`
	Configs   []portableConfig `json:"configs"`
}
type portableConfig struct {
	Name string          `json:"name"`
	Data json.RawMessage `json:"data"`
}

func encodeTransfer(g *Group) (string, error) {
	migrateSubscriptions(g)
	p := portableProfile{Version: 1, Name: g.Name, Identity: g.Identity, Sources: []portableSource{}}
	for _, s := range g.Subscriptions {
		source := portableSource{Name: s.Name, URL: s.URL, Configs: []portableConfig{}}
		if s.URL != "" {
			// The receiver fetches current configurations with the shared identity.
			p.Sources = append(p.Sources, source)
			continue
		}
		if s.Report != nil {
			source.FetchedAt = s.Report.FetchedAt
		}
		for _, server := range g.Servers {
			if server.SubscriptionID == s.ID {
				data := server.Outbound
				if len(server.Profile) > 0 {
					data = server.Profile
				}
				source.Configs = append(source.Configs, portableConfig{Name: server.Name, Data: data})
			}
		}
		p.Sources = append(p.Sources, source)
	}
	return encodePortable(p)
}
func encodePortable(p portableProfile) (string, error) {
	b, err := json.Marshal(p)
	if err != nil {
		return "", err
	}
	if len(b) > transferLimit {
		return "", fail(413, "Профиль больше 8 МБ. Уменьшите число конфигураций перед переносом.")
	}
	var compressed bytes.Buffer
	writer := gzip.NewWriter(&compressed)
	if _, err = writer.Write(b); err != nil {
		return "", err
	}
	if err = writer.Close(); err != nil {
		return "", err
	}
	return "SVOI1." + base64.RawURLEncoding.EncodeToString(compressed.Bytes()), nil
}
func decodeTransfer(code string) (Group, error) {
	invalid := fail(400, "Код профиля повреждён. Скопируйте его целиком или выберите файл .svoi.")
	if len(code) > transferCodeLimit {
		return Group{}, fail(413, "Файл профиля превышает 12 МБ")
	}
	code = strings.Join(strings.Fields(strings.TrimPrefix(code, "\ufeff")), "")
	if !strings.HasPrefix(code, "SVOI1.") {
		return Group{}, fail(400, "Нужен код профиля SVOI1. Старые короткие инвайты работают только внутри одного сервиса; создайте новый через «Поделиться профилем».")
	}
	compressed, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(code, "SVOI1."))
	if err != nil {
		return Group{}, invalid
	}
	reader, err := gzip.NewReader(bytes.NewReader(compressed))
	if err != nil {
		return Group{}, invalid
	}
	defer reader.Close()
	b, err := io.ReadAll(io.LimitReader(reader, transferLimit+1))
	if err != nil {
		return Group{}, invalid
	}
	if len(b) > transferLimit {
		return Group{}, fail(413, "Распакованный профиль превышает 8 МБ")
	}
	var p portableProfile
	decoder := json.NewDecoder(bytes.NewReader(b))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&p) != nil || decoder.Decode(&struct{}{}) != io.EOF {
		return Group{}, invalid
	}
	if p.Version != 1 {
		return Group{}, fail(400, "Эта версия формата профиля не поддерживается")
	}
	if !validText(p.Name, 60) || !validIdentity(p.Identity) || len(p.Sources) > 32 {
		return Group{}, fail(400, "Некорректные параметры профиля")
	}
	g := Group{ID: secret(), Name: p.Name, Identity: p.Identity}
	for _, source := range p.Sources {
		if !validText(source.Name, 60) || len(source.Configs) > 2000 {
			return Group{}, fail(400, "Некорректный источник в профиле")
		}
		if source.URL != "" {
			if _, err = subscriptionURL(source.URL); err != nil {
				return Group{}, err
			}
		}
		g.Subscriptions = append(g.Subscriptions, Subscription{ID: secret(), Name: source.Name, URL: source.URL})
		if source.URL != "" {
			// Also discard cached remote configurations from prebeta.2 codes.
			syncLegacySubscription(&g)
			continue
		}
		servers := []ServerConfig{}
		for _, raw := range source.Configs {
			var data object
			if json.Unmarshal(raw.Data, &data) != nil || data == nil {
				return Group{}, invalid
			}
			var server ServerConfig
			if _, full := data["outbounds"]; full {
				server, err = serverFromProfile(data, len(servers)+1)
			} else {
				server, err = serverFromOutbound(raw.Name, data)
			}
			if err != nil {
				return Group{}, fail(422, "В профиле есть неподдерживаемая конфигурация. Обновите SVOI на обоих устройствах.")
			}
			if raw.Name != "" {
				if !validText(raw.Name, 512) {
					return Group{}, invalid
				}
				server.Name = raw.Name
			}
			servers = append(servers, server)
		}
		var report *Report
		if len(servers) > 0 {
			report = &Report{Count: len(servers), Format: "Перенос профиля", FetchedAt: source.FetchedAt}
		}
		replaceSubscriptionServers(&g, &g.Subscriptions[len(g.Subscriptions)-1], servers, report)
	}
	return g, nil
}

func (a *App) transferAPI(w http.ResponseWriter, r *http.Request) error {
	if r.URL.Path == "/api/transfer/export" && r.Method == "POST" {
		a.mu.Lock()
		defer a.mu.Unlock()
		g, d, err := a.auth(r)
		if err != nil {
			return err
		}
		if !d.Device.Owner {
			return fail(403, "Поделиться профилем может владелец")
		}
		if a.limited(r) {
			return fail(429, "Слишком много запросов. Подождите минуту.")
		}
		code, err := encodeTransfer(g)
		if err != nil {
			return err
		}
		remote, embedded := 0, 0
		for _, s := range g.Subscriptions {
			if s.URL != "" {
				remote++
			} else {
				for _, v := range g.Servers {
					if v.SubscriptionID == s.ID {
						embedded++
					}
				}
			}
		}
		writeJSON(w, 200, map[string]any{"code": code, "name": g.Name, "sources": len(g.Subscriptions), "servers": embedded, "remoteSources": remote})
		return nil
	}
	if r.Method != "POST" || (r.URL.Path != "/api/transfer/preview" && r.URL.Path != "/api/transfer/import") {
		return fail(404, "Метод переноса не найден")
	}
	a.mu.Lock()
	limited := a.limited(r)
	a.mu.Unlock()
	if limited {
		return fail(429, "Слишком много попыток. Подождите минуту.")
	}
	var in struct {
		Code       string `json:"code"`
		DeviceName string `json:"deviceName"`
		Platform   string `json:"platform"`
		Replace    bool   `json:"replace"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<20))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&in) != nil || decoder.Decode(&struct{}{}) != io.EOF {
		return fail(400, "Не удалось прочитать профиль")
	}
	imported, err := decodeTransfer(in.Code)
	if err != nil {
		return err
	}
	if r.URL.Path == "/api/transfer/preview" {
		// Preview contains only public metadata and never triggers subscription requests.
		writeJSON(w, 200, map[string]any{"name": imported.Name, "hwid": imported.Identity.HWID, "sources": publicSubscriptions(&imported), "servers": len(imported.Servers)})
		return nil
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if in.Replace {
		g, d, err := a.auth(r)
		if err != nil {
			return err
		}
		if !d.Device.Owner {
			return fail(403, "Обновить профиль может владелец")
		}
		err = a.transaction(func() error {
			g.Name = imported.Name
			g.Identity = imported.Identity
			g.Subscriptions = imported.Subscriptions
			g.Servers = imported.Servers
			syncLegacySubscription(g)
			return nil
		})
		if err != nil {
			return err
		}
		writeJSON(w, 200, map[string]any{"group": snapshot(g, d)})
		return nil
	}
	if !validText(in.DeviceName, 60) || !validText(in.Platform, 32) {
		return fail(400, "Укажите имя устройства и платформу")
	}
	if len(a.state.Groups) >= 1000 {
		return fail(409, "Лимит локальных профилей достигнут")
	}
	token := secret()
	member := Member{Device: Device{ID: secret(), Name: strings.TrimSpace(in.DeviceName), Platform: in.Platform, Owner: true, Joined: time.Now().UTC()}, TokenHash: digest(token)}
	imported.Devices = []Member{member}
	if err = a.transaction(func() error { a.state.Groups = append(a.state.Groups, imported); return nil }); err != nil {
		return err
	}
	writeJSON(w, 201, map[string]any{"token": token, "group": snapshot(&imported, &member)})
	return nil
}
