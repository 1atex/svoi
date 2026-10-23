package main

import (
	"encoding/json"
	"errors"
	"fmt"
)

func serviceOutbound(protocol string) bool {
	switch protocol {
	case "freedom", "blackhole", "dns", "loopback":
		return true
	}
	return false
}

// A JSON profile is a routing graph, not a bag of independent servers.
// The representative endpoint is only for display; the complete graph runs.
func serverFromProfile(profile object, index int) (ServerConfig, error) {
	for _, key := range []string{"api", "metrics", "reverse"} {
		if profile[key] != nil {
			return ServerConfig{}, fmt.Errorf("профили с разделом %s пока не поддерживаются", key)
		}
	}
	data, err := json.Marshal(profile)
	if err != nil {
		return ServerConfig{}, err
	}
	outbounds, _ := profile["outbounds"].([]any)
	var representative ServerConfig
	nodes := 0
	for _, raw := range outbounds {
		out, ok := raw.(map[string]any)
		if !ok {
			return ServerConfig{}, errors.New("outbounds содержит не объект")
		}
		if serviceOutbound(str(out["protocol"])) {
			continue
		}
		nodes++
		if representative.Address != "" {
			continue
		}
		// Metadata extraction must not rename graph tags or reject a valid chain.
		display := object{}
		for k, v := range out {
			display[k] = v
		}
		delete(display, "proxySettings")
		delete(display, "sendThrough")
		representative, _ = serverFromOutbound(str(profile["remarks"]), display)
	}
	if representative.Address == "" {
		return ServerConfig{}, errors.New("в профиле нет поддерживаемого VPN-узла")
	}
	if name := str(profile["remarks"]); name != "" {
		representative.Name = name
	} else {
		representative.Name = fmt.Sprintf("Профиль %d · %s", index, representative.Address)
	}
	representative.ID = digest(string(data))[:24]
	representative.FullProfile = true
	representative.NodeCount = nodes
	representative.Profile = data
	// Only full-profile data is authoritative. Do not persist an alternative,
	// flattened outbound that could accidentally bypass the profile's routing.
	representative.Outbound = nil
	if _, err = buildProfileConfig(data, 10808, 10809, "local"); err != nil {
		return ServerConfig{}, err
	}
	return representative, nil
}

func buildProfileConfig(data []byte, socksPort, httpPort int, mode string) ([]byte, error) {
	var config object
	if err := json.Unmarshal(data, &config); err != nil {
		return nil, err
	}
	if config == nil {
		return nil, errors.New("пустой профиль")
	}
	// Collect all tag strings, including synthetic loopback inbound tags, before
	// assigning our own names. Existing outbound tags are never rewritten.
	used := map[string]bool{}
	var collect func(any)
	collect = func(v any) {
		switch x := v.(type) {
		case string:
			used[x] = true
		case []any:
			for _, v := range x {
				collect(v)
			}
		case map[string]any:
			for _, v := range x {
				collect(v)
			}
		}
	}
	collect(config)
	unique := func(base string) string {
		name := base
		for n := 1; used[name]; n++ {
			name = fmt.Sprintf("%s-%d", base, n)
		}
		used[name] = true
		return name
	}
	originals, _ := config["inbounds"].([]any)
	templates := map[string]object{}
	for _, raw := range originals {
		in, ok := raw.(map[string]any)
		if !ok {
			return nil, errors.New("inbounds содержит не объект")
		}
		protocol := str(in["protocol"])
		if protocol != "socks" && protocol != "http" && protocol != "tun" {
			return nil, fmt.Errorf("вход %s не поддерживается в локальном профиле", protocol)
		}
		if templates[protocol] != nil {
			return nil, fmt.Errorf("несколько входов %s требуют отдельной настройки портов", protocol)
		}
		templates[protocol] = in
	}
	tags := map[string]string{}
	for _, p := range []string{"socks", "http", "tun"} {
		tags[p] = str(templates[p]["tag"])
		if tags[p] == "" {
			tags[p] = unique("svoi-" + p)
		}
	}
	if tags["socks"] == tags["http"] || tags["tun"] == tags["http"] || tags["tun"] == tags["socks"] {
		return nil, errors.New("повторяющиеся теги входов")
	}
	inbounds := []any{}
	for _, p := range []string{"socks", "http"} {
		port := httpPort
		settings := object{}
		if p == "socks" {
			port = socksPort
			settings = object{"auth": "noauth", "udp": true}
		}
		in := object{"tag": tags[p], "listen": "127.0.0.1", "port": port, "protocol": p, "settings": settings}
		if sniffing := templates[p]["sniffing"]; sniffing != nil {
			in["sniffing"] = sniffing
		}
		inbounds = append(inbounds, in)
	}
	if mode == "tun" {
		tun := tunInbound(tags["tun"])
		for _, p := range []string{"tun", "socks", "http"} {
			if sniff := templates[p]["sniffing"]; sniff != nil {
				tun["sniffing"] = sniff
				break
			}
		}
		inbounds = append(inbounds, tun)
	}
	// Preserve inbound routing for each original local entry. Add the new HTTP,
	// SOCKS or TUN entry to the same rules without touching loopback/DNS tags.
	aliases := map[string][]string{}
	for _, p := range []string{"socks", "http", "tun"} {
		old := str(templates[p]["tag"])
		if old == "" {
			continue
		}
		dest := []string{tags[p]}
		if p == "tun" {
			dest = []string{tags["socks"], tags["http"]}
		} else if templates["socks"] == nil {
			dest = append(dest, tags["socks"])
		} else if templates["http"] == nil {
			dest = append(dest, tags["http"])
		}
		if mode == "tun" {
			dest = append(dest, tags["tun"])
		}
		aliases[old] = dest
	}
	rules, _ := obj(config["routing"])["rules"].([]any)
	for _, raw := range rules {
		rule := obj(raw)
		oldTags, ok := rule["inboundTag"].([]any)
		if !ok {
			continue
		}
		newTags := []any{}
		seen := map[string]bool{}
		for _, rawTag := range oldTags {
			tag := str(rawTag)
			dest := aliases[tag]
			if len(dest) == 0 {
				dest = []string{tag}
			}
			for _, d := range dest {
				if !seen[d] {
					seen[d] = true
					newTags = append(newTags, d)
				}
			}
		}
		rule["inboundTag"] = newTags
	}
	config["inbounds"] = inbounds
	if mode == "tun" {
		configureTunDNS(config, tags["tun"])
	}
	// Runtime diagnostics go to the app, never a path supplied by a subscription.
	config["log"] = object{"loglevel": "warning"}
	return json.MarshalIndent(config, "", "  ")
}
