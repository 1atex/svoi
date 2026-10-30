package main

import (
	"encoding/json"
	"strings"
)

func (s *ServerConfig) updateProtocolMetadata() {
	s.Protocols = nil
	if !s.FullProfile {
		return
	}
	var profile object
	if json.Unmarshal(s.Profile, &profile) != nil {
		return
	}
	seen := map[string]bool{}
	outbounds, _ := profile["outbounds"].([]any)
	for _, raw := range outbounds {
		out := obj(raw)
		protocol := strings.ToLower(strings.TrimSpace(str(out["protocol"])))
		if protocol == "" || serviceOutbound(protocol) {
			continue
		}
		if protocol == "hysteria" && number(obj(out["settings"])["version"]) == 2 {
			protocol = "hysteria2"
		}
		if !seen[protocol] {
			seen[protocol] = true
			s.Protocols = append(s.Protocols, protocol)
		}
	}
}
