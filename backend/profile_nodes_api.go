package main

import (
	"encoding/json"
	"net/http"
	"time"
)

func (a *App) extractServerNodesAPI(w http.ResponseWriter, r *http.Request, id string) error {
	var in struct {
		Acknowledge bool `json:"acknowledgeProfileRulesOmitted"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&in) != nil || !in.Acknowledge {
		return fail(400, "Подтвердите создание отдельных узлов без правил и балансировщиков профиля.")
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	g, d, err := a.auth(r)
	if err != nil {
		return err
	}
	if !d.Device.Owner {
		return fail(403, "Создать копии может только владелец группы")
	}
	var source *ServerConfig
	for i := range g.Servers {
		if g.Servers[i].ID == id {
			source = &g.Servers[i]
			break
		}
	}
	if source == nil {
		return fail(404, "Профиль не найден")
	}
	if source.SourceProfileCore != "" {
		return fail(422, "Этот профиль содержит группы и маршруты "+source.SourceProfileCore+". Разделение на узлы пока недоступно; используйте профиль целиком.")
	}
	nodes, err := extractProfileNodes(*source)
	if err != nil {
		return err
	}
	migrateSubscriptions(g)
	if len(g.Subscriptions) >= 32 {
		return fail(409, "В группе уже 32 источника")
	}
	name := "Узлы: " + source.Name
	report := Report{Count: len(nodes), Format: "Отдельные узлы без правил исходного профиля", FetchedAt: time.Now().UTC()}
	if err = a.transaction(func() error {
		g.Subscriptions = append(g.Subscriptions, Subscription{ID: secret(), Name: name})
		replaceSubscriptionServers(g, &g.Subscriptions[len(g.Subscriptions)-1], nodes, &report)
		return nil
	}); err != nil {
		return err
	}
	writeJSON(w, 200, snapshot(g, d))
	return nil
}
