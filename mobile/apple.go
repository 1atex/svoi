package mobile

import (
	"encoding/json"
	"errors"
	"runtime/debug"
)

type appleProtector struct{}

func (appleProtector) Protect(int32) bool { return true }

func StartApple(config string, fd int32, assets string) error {
	debug.SetMemoryLimit(32 << 20)
	debug.SetGCPercent(50)
	return Start(config, fd, assets, appleProtector{})
}

func (s *Session) AppleConfig(token, serverID string) (string, error) {
	raw, err := s.Config(token, serverID)
	if err != nil {
		return "", err
	}
	return appleConfig(raw)
}

func appleConfig(raw string) (string, error) {
	var config map[string]any
	if err := json.Unmarshal([]byte(raw), &config); err != nil {
		return "", err
	}
	inbounds, _ := config["inbounds"].([]any)
	kept := []any{}
	tuns := 0
	for _, item := range inbounds {
		inbound, ok := item.(map[string]any)
		if !ok {
			return "", errors.New("Некорректный входящий протокол")
		}
		protocol, _ := inbound["protocol"].(string)
		if protocol == "http" || protocol == "socks" {
			continue
		}
		if protocol == "tun" {
			tuns++
			inbound["settings"] = map[string]any{"name": "SVOI", "mtu": 1500}
		}
		kept = append(kept, inbound)
	}
	if tuns != 1 {
		return "", errors.New("Конфигурация должна содержать один входящий TUN")
	}
	config["inbounds"] = kept
	config["log"] = map[string]any{"access": "none", "loglevel": "warning"}
	encoded, err := json.Marshal(config)
	return string(encoded), err
}
