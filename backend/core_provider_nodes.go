package main

import (
	"encoding/json"
	"strings"
)

func providerPrimarySelector(core string, profile object) object {
	key, tagKey, membersKey := "outbounds", "tag", "outbounds"
	target := str(obj(profile["route"])["final"])
	if core == "mihomo" {
		if mode := strings.ToLower(str(profile["mode"])); mode != "" && mode != "rule" {
			return nil
		}
		key, tagKey, membersKey = "proxy-groups", "name", "proxies"
		rules, _ := profile["rules"].([]any)
		for _, raw := range rules {
			parts := strings.Split(str(raw), ",")
			if len(parts) == 2 && strings.EqualFold(strings.TrimSpace(parts[0]), "MATCH") {
				target = strings.TrimSpace(parts[1])
				break
			}
		}
	}
	entries, _ := profile[key].([]any)
	if core == "sing-box" && target == "" && len(entries) > 0 {
		target = str(obj(entries[0])[tagKey])
	}
	if target == "" {
		return nil
	}
	var selector object
	for _, raw := range entries {
		entry := obj(raw)
		if str(entry[tagKey]) == target {
			if selector != nil {
				return nil
			}
			selector = entry
		}
	}
	if selector == nil {
		return nil
	}
	kind := str(selector["type"])
	if (core == "sing-box" && kind != "selector") || (core == "mihomo" && kind != "select") {
		return nil
	}
	if _, ok := selector[membersKey].([]any); !ok {
		return nil
	}
	return selector
}

func providerSelectableNodes(core string, profile object) []object {
	selector := providerPrimarySelector(core, profile)
	if selector == nil {
		return nil
	}
	key, tagKey, memberKey := "outbounds", "tag", "outbounds"
	if core == "mihomo" {
		key, tagKey, memberKey = "proxies", "name", "proxies"
	}
	members, _ := selector[memberKey].([]any)
	allowed := map[string]bool{}
	for _, member := range members {
		allowed[str(member)] = true
	}
	entries, _ := profile[key].([]any)
	counts := map[string]int{}
	for _, raw := range entries {
		counts[str(obj(raw)[tagKey])]++
	}
	nodes := []object{}
	for _, raw := range entries {
		node := obj(raw)
		tag := str(node[tagKey])
		if tag == "" || len(tag) > 512 || counts[tag] != 1 || !allowed[tag] || nativeProviderService(nativeProviderProtocol(str(node["type"]))) {
			continue
		}
		nodes = append(nodes, node)
	}
	return nodes
}

func applyProviderNodeSelection(core string, profile object, target string) error {
	if target == "" {
		return nil
	}
	tagKey, memberKey := "tag", "outbounds"
	if core == "mihomo" {
		tagKey, memberKey = "name", "proxies"
	}
	found := false
	for _, node := range providerSelectableNodes(core, profile) {
		if str(node[tagKey]) == target {
			found = true
			break
		}
	}
	if !found {
		return fail(422, "Выбранного сервера нет в основной группе профиля. Обновите подписку и выберите сервер заново.")
	}
	selector := providerPrimarySelector(core, profile)
	if core == "sing-box" {
		selector["default"] = target
		return nil
	}
	members, _ := selector[memberKey].([]any)
	ordered := []any{target}
	for _, member := range members {
		if str(member) != target {
			ordered = append(ordered, member)
		}
	}
	selector[memberKey] = ordered
	return nil
}

func providerServerViews(parent ServerConfig) []ServerConfig {
	if parent.SourceProfileCore == "" || parent.NativeTarget != "" {
		return []ServerConfig{parent}
	}
	var profile object
	if json.Unmarshal(parent.Profile, &profile) != nil {
		return []ServerConfig{parent}
	}
	nodes := providerSelectableNodes(parent.SourceProfileCore, profile)
	if len(nodes) == 0 {
		return []ServerConfig{parent}
	}
	root := parent
	root.Name = "Профиль провайдера · выбор по умолчанию"
	views := []ServerConfig{root}
	for _, node := range nodes {
		tagKey, portKey := "tag", "server_port"
		if parent.SourceProfileCore == "mihomo" {
			tagKey, portKey = "name", "port"
		}
		tag := str(node[tagKey])
		view := parent
		baseID := parent.ID
		if parent.SubscriptionID != "" && parent.SubscriptionCore == parent.SourceProfileCore {
			baseID = parent.SubscriptionID + "-" + parent.SourceProfileCore + "-node"
		}
		view.ID = baseID + "~" + digest(tag)[:16]
		view.NativeTarget, view.ProfileNode = tag, true
		view.Name = strings.TrimSpace(tag)
		view.Protocol = nativeProviderProtocol(str(node["type"]))
		view.Protocols = []string{view.Protocol}
		view.Address = str(node["server"])
		if port, ok := node[portKey].(float64); ok {
			view.Port = int(port)
		}
		view.Network, view.Security = "tcp", "none"
		if parent.SourceProfileCore == "mihomo" {
			if network := str(node["network"]); network != "" {
				view.Network = network
			}
			if node["tls"] == true {
				view.Security = "tls"
			}
			if obj(node["reality-opts"]) != nil {
				view.Security = "reality"
			}
		} else {
			if network := str(obj(node["transport"])["type"]); network != "" {
				view.Network = network
			}
			if obj(node["tls"])["enabled"] == true {
				view.Security = "tls"
			}
			if obj(obj(node["tls"])["reality"])["enabled"] == true {
				view.Security = "reality"
			}
		}
		if view.Protocol == "hysteria" || view.Protocol == "hysteria2" {
			view.Network, view.Security = "hysteria", "tls"
		}
		views = append(views, view)
	}
	return views
}

func groupServerViews(g *Group) []ServerConfig {
	views := make([]ServerConfig, 0, len(g.Servers))
	for _, server := range g.Servers {
		views = append(views, providerServerViews(server)...)
	}
	return views
}
