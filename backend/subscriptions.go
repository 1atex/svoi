package backend

import (
	"net/http"
	"net/url"
	"strings"
)

type Subscription struct {
	ID     string  `json:"id"`
	Name   string  `json:"name"`
	URL    string  `json:"url,omitempty"`
	Report *Report `json:"report,omitempty"`
}

func migrateSubscriptions(g *Group) {
	if len(g.Subscriptions) > 0 || (g.SubscriptionURL == "" && len(g.Servers) == 0) {
		return
	}
	name := "Импортированные конфигурации"
	if u, err := url.Parse(g.SubscriptionURL); err == nil && u.Hostname() != "" {
		name = u.Hostname()
	}
	id := "legacy"
	g.Subscriptions = []Subscription{{ID: id, Name: name, URL: g.SubscriptionURL, Report: g.LastRefresh}}
	for i := range g.Servers {
		g.Servers[i].SubscriptionID = id
	}
}
func subscriptionByID(g *Group, id string) *Subscription {
	migrateSubscriptions(g)
	for i := range g.Subscriptions {
		if g.Subscriptions[i].ID == id || id == "" {
			return &g.Subscriptions[i]
		}
	}
	return nil
}
func syncLegacySubscription(g *Group) {
	g.SubscriptionURL = ""
	g.LastRefresh = nil
	if len(g.Subscriptions) > 0 {
		g.SubscriptionURL = g.Subscriptions[0].URL
		g.LastRefresh = g.Subscriptions[0].Report
	}
}
func replaceSubscriptionServers(g *Group, s *Subscription, servers []ServerConfig, report *Report) {
	kept := make([]ServerConfig, 0, len(g.Servers)+len(servers))
	for _, v := range g.Servers {
		if v.SubscriptionID != s.ID {
			kept = append(kept, v)
		}
	}
	for _, v := range servers {
		v.SubscriptionID = s.ID
		if s.ID != "legacy" {
			v.ID = s.ID + "-" + v.ID
		}
		kept = append(kept, v)
	}
	g.Servers = kept
	s.Report = report
	syncLegacySubscription(g)
}
func publicSubscriptions(g *Group) []map[string]any {
	result := []map[string]any{}
	for _, s := range g.Subscriptions {
		host := ""
		if u, err := url.Parse(s.URL); err == nil {
			host = u.Hostname()
		}
		count := 0
		for _, v := range g.Servers {
			if v.SubscriptionID == s.ID {
				count++
			}
		}
		result = append(result, map[string]any{"id": s.ID, "name": s.Name, "host": host, "remote": s.URL != "", "report": s.Report, "count": count})
	}
	return result
}

func (a *App) subscriptionsAPI(w http.ResponseWriter, r *http.Request, g *Group, d *Member) error {
	migrateSubscriptions(g)
	id := strings.TrimPrefix(r.URL.Path, "/api/subscriptions/")
	if r.Method == "POST" && r.URL.Path == "/api/subscriptions" {
		in, err := decode(w, r)
		if err != nil {
			return err
		}
		u, err := subscriptionURL(in.URL)
		if err != nil {
			return err
		}
		name := strings.TrimSpace(in.Name)
		if name == "" {
			name = u.Hostname()
		}
		if !validText(name, 60) {
			return fail(400, "Название: от 1 до 60 символов")
		}
		if len(g.Subscriptions) >= 32 {
			return fail(409, "В группе уже 32 источника")
		}
		for _, s := range g.Subscriptions {
			if s.URL == in.URL {
				return fail(409, "Эта подписка уже добавлена")
			}
		}
		s := Subscription{ID: secret(), Name: name, URL: in.URL}
		if err = a.transaction(func() error { g.Subscriptions = append(g.Subscriptions, s); syncLegacySubscription(g); return nil }); err != nil {
			return err
		}
		writeJSON(w, 201, map[string]any{"id": s.ID, "group": snapshot(g, d)})
		return nil
	}
	s := subscriptionByID(g, id)
	if s == nil {
		return fail(404, "Подписка не найдена")
	}
	if r.Method == "DELETE" {
		err := a.transaction(func() error {
			replaceSubscriptionServers(g, s, nil, nil)
			for i := range g.Subscriptions {
				if g.Subscriptions[i].ID == id {
					g.Subscriptions = append(g.Subscriptions[:i], g.Subscriptions[i+1:]...)
					break
				}
			}
			syncLegacySubscription(g)
			return nil
		})
		if err != nil {
			return err
		}
		writeJSON(w, 200, snapshot(g, d))
		return nil
	}
	if r.Method == "PUT" {
		in, err := decode(w, r)
		if err != nil {
			return err
		}
		if !validText(in.Name, 60) {
			return fail(400, "Название: от 1 до 60 символов")
		}
		if in.URL != "" {
			if _, err = subscriptionURL(in.URL); err != nil {
				return err
			}
			for _, other := range g.Subscriptions {
				if other.ID != id && other.URL == in.URL {
					return fail(409, "Эта подписка уже добавлена")
				}
			}
		}
		err = a.transaction(func() error {
			s.Name = strings.TrimSpace(in.Name)
			if in.URL != "" && in.URL != s.URL {
				s.URL = in.URL
				replaceSubscriptionServers(g, s, nil, nil)
			}
			syncLegacySubscription(g)
			return nil
		})
		if err != nil {
			return err
		}
		writeJSON(w, 200, snapshot(g, d))
		return nil
	}
	return fail(404, "Метод подписок не найден")
}
