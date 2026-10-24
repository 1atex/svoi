package backend

import "encoding/json"

func buildXrayConfig(server ServerConfig, socksPort, httpPort int, mode string) ([]byte, error) {
	data, err := buildBaseXrayConfig(server, socksPort, httpPort, mode)
	if err != nil || mode != "tun" || server.RuntimeApps == nil || server.RuntimeApps.Mode == "all" {
		return data, err
	}
	var config object
	if err = json.Unmarshal(data, &config); err != nil {
		return nil, err
	}
	if err = applyAppRouting(config, *server.RuntimeApps); err != nil {
		return nil, err
	}
	return json.MarshalIndent(config, "", "  ")
}

func applyAppRouting(config object, settings AppRouting) error {
	check := LocalSettings{Routing: settings}
	if err := validateSettings(&check); err != nil {
		return err
	}
	settings = check.Routing
	if settings.Mode == "all" {
		return nil
	}
	used := map[string]bool{}
	var walk func(any)
	walk = func(v any) {
		switch x := v.(type) {
		case string:
			used[x] = true
		case []any:
			for _, v := range x {
				walk(v)
			}
		case map[string]any:
			for _, v := range x {
				walk(v)
			}
		}
	}
	walk(config)
	unique := func(tag string) string {
		for used[tag] {
			tag += "-x"
		}
		used[tag] = true
		return tag
	}
	capture, direct, loop := unique("svoi-app-capture"), unique("svoi-app-direct"), unique("svoi-app-loop")
	tunTag := ""
	for _, v := range config["inbounds"].([]any) {
		in := obj(v)
		if str(in["protocol"]) == "tun" {
			tunTag = str(in["tag"])
			in["tag"] = capture
			break
		}
	}
	if tunTag == "" {
		return fail(422, "В конфигурации отсутствует TUN")
	}
	out := config["outbounds"].([]any)
	config["outbounds"] = append(out, object{"tag": direct, "protocol": "freedom"}, object{"tag": loop, "protocol": "loopback", "settings": object{"inboundTag": tunTag}})
	selected, other := loop, direct
	if settings.Mode == "exclude" {
		selected, other = direct, loop
	}
	gate := []any{
		object{"type": "field", "inboundTag": []string{capture}, "port": "53", "outboundTag": loop, "ruleTag": "SVOI shared DNS"},
		object{"type": "field", "inboundTag": []string{capture}, "process": settings.Processes, "outboundTag": selected, "ruleTag": "SVOI selected apps"},
		object{"type": "field", "inboundTag": []string{capture}, "outboundTag": other, "ruleTag": "SVOI other apps"},
	}
	routing := obj(config["routing"])
	if routing == nil {
		routing = object{}
		config["routing"] = routing
	}
	rules, _ := routing["rules"].([]any)

	if str(routing["script"]) != "" {
		return fail(422, "Разделение приложений несовместимо с routing.script этого профиля")
	}
	routing["rules"] = append(gate, rules...)
	return nil
}
