package main

import (
	"encoding/json"
	"fmt"
)

// extractProfileNodes is only for an explicit request to create independent
// copies. Connecting or probing a full profile must never call it implicitly:
// the copies deliberately do not carry provider routing, DNS or balancers.
func extractProfileNodes(server ServerConfig) ([]ServerConfig, error) {
	if len(server.Profile) == 0 {
		return nil, fail(422, "Выберите полный Xray-профиль для создания отдельных узлов")
	}
	var profile struct {
		Outbounds []json.RawMessage `json:"outbounds"`
	}
	if err := json.Unmarshal(server.Profile, &profile); err != nil || len(profile.Outbounds) == 0 {
		return nil, fail(422, "В полном профиле не найден список узлов")
	}
	nodes := []ServerConfig{}
	seen := map[string]bool{}
	for index, raw := range profile.Outbounds {
		var outbound object
		if err := json.Unmarshal(raw, &outbound); err != nil || outbound == nil {
			return nil, fail(422, "В профиле найден некорректный выход")
		}
		switch str(outbound["protocol"]) {
		case "vless", "vmess", "trojan", "shadowsocks":
		default:
			continue
		}
		// These options reference another outbound or a local interface. Removing
		// them would change the route; retaining them would leave a broken copy.
		if outbound["proxySettings"] != nil || outbound["sendThrough"] != nil || str(obj(obj(outbound["streamSettings"])["sockopt"])["dialerProxy"]) != "" {
			return nil, fail(422, "Узел зависит от цепочки выходов или локального интерфейса и не может быть скопирован отдельно")
		}
		name := fmt.Sprintf("%s · %s", server.Name, defaultString(str(outbound["tag"]), fmt.Sprintf("Узел %d", index+1)))
		node, err := serverFromOutbound(name, outbound)
		if err != nil {
			return nil, fail(422, fmt.Sprintf("Не удалось выделить узел %d: %s", index+1, err))
		}
		// serverFromOutbound normalizes its copy's tag. Restore the entire original
		// object so credentials, transport/security options and provider values are
		// retained byte for byte; the native translator validates support separately.
		node.Outbound = append(json.RawMessage(nil), raw...)
		node.ID = digest(string(raw))[:24]
		if seen[node.ID] {
			continue
		}
		seen[node.ID] = true
		nodes = append(nodes, node)
	}
	if len(nodes) == 0 {
		return nil, fail(422, "В профиле нет отдельных узлов VLESS, VMess, Trojan или Shadowsocks")
	}
	return nodes, nil
}
