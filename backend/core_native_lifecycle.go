package main

import (
	"encoding/json"
	"fmt"
	"net"
	"regexp"
	"time"
)

var coreANSI = regexp.MustCompile(`\x1b\[[0-?]*[ -/]*[@-~]`)

func stripCoreANSI(text string) string { return coreANSI.ReplaceAllString(text, "") }

func coreStartupConfig(core string, raw []byte) ([]byte, error) {
	if core != "sing-box" {
		return raw, nil
	}
	var config object
	if err := json.Unmarshal(raw, &config); err != nil {
		return nil, err
	}
	config["log"] = object{"level": "info", "timestamp": true, "disabled": false}
	return json.Marshal(config)
}

func nativeTunDeviceFromConfig(core string, raw []byte) string {
	var config object
	if json.Unmarshal(raw, &config) != nil {
		return ""
	}
	if core == "mihomo" {
		return str(obj(config["tun"])["device"])
	}
	inbounds, _ := config["inbounds"].([]any)
	for _, value := range inbounds {
		inbound := obj(value)
		if inbound["type"] == "tun" {
			return str(inbound["interface_name"])
		}
	}
	return ""
}

func nativeTunInterfaceReady(name string) bool {
	device, err := net.InterfaceByName(name)
	if err != nil || device.Flags&net.FlagUp == 0 {
		return false
	}
	addresses, err := device.Addrs()
	return err == nil && len(addresses) > 0
}

func waitNativeTunStopped(name string) error {
	deadline := time.Now().Add(3 * time.Second)
	for nativeTunInterfaceReady(name) {
		if time.Now().After(deadline) {
			return fmt.Errorf("TUN-адаптер %s ещё активен после остановки ядра. Повторите отключение; если ошибка сохраняется, перезапустите Windows", name)
		}
		time.Sleep(50 * time.Millisecond)
	}
	return nil
}
