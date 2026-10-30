package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

type CoreCapability struct {
	ID             string   `json:"id"`
	Installed      bool     `json:"installed"`
	Available      bool     `json:"available"`
	Version        string   `json:"version"`
	SupportedModes []string `json:"supportedModes"`
	FullProfiles   bool     `json:"fullProfiles"`
	ProfileSupport string   `json:"profileSupport"`
}
type CoreCapabilities struct {
	Cores          []CoreCapability `json:"cores"`
	SupportedModes []string         `json:"supportedModes"`
	FullProfiles   bool             `json:"fullProfiles"`
	ProfileSupport string           `json:"profileSupport"`
}

// FullProfiles retains its existing meaning: arbitrary supported Xray profile
// semantics. Optional cores accept a validated subset, advertised separately.
func coreProfileSupport(id string) string {
	if id == "" || id == "xray" {
		return "native"
	}
	return "limited"
}

func (e *Engine) coreID() string {
	if e.core == "" {
		return "xray"
	}
	return e.core
}

func (e *Engine) probeEngine(dir string) *Engine {
	e.mu.Lock()
	defer e.mu.Unlock()
	return &Engine{binary: e.binary, core: e.coreID(), xrayBinary: e.xrayBinary, dir: dir, checkURL: e.checkURL, status: EngineStatus{Core: e.coreID(), State: "stopped", Available: e.status.Available, Capabilities: e.status.Capabilities, Logs: []string{}}}
}
func coreModes(id string) []string {
	if runtime.GOOS != "windows" {
		if id == "xray" {
			return []string{"local", "tun"}
		}
		return []string{"local"}
	}
	return []string{"local", "system", "tun"}
}
func coreArgs(id, action, path, dir string) []string {
	switch id {
	case "sing-box":
		switch action {
		case "version":
			return []string{"version"}
		case "check":
			return []string{"check", "-D", dir, "-c", path}
		default:
			return []string{"run", "-D", dir, "-c", path}
		}
	case "mihomo":
		switch action {
		case "version":
			return []string{"-v"}
		case "check":
			return []string{"-t", "-f", path, "-d", dir}
		default:
			return []string{"-f", path, "-d", dir}
		}
	default:
		switch action {
		case "version":
			return []string{"version"}
		case "check":
			return []string{"run", "-test", "-c", path}
		default:
			return []string{"run", "-c", path}
		}
	}
}
func (e *Engine) coreBinary(id string) string {
	if id == "xray" {
		return e.xrayBinary
	}
	name := id
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	return filepath.Join(filepath.Dir(e.xrayBinary), name)
}
func (e *Engine) initializeCores() {
	e.xrayBinary = e.binary
	e.core = "xray"
	e.refreshCores()
	var selection struct {
		Core string `json:"core"`
	}
	if raw, err := os.ReadFile(filepath.Join(e.dir, "core-selection.json")); err == nil && json.Unmarshal(raw, &selection) == nil {
		for _, c := range e.status.Capabilities.Cores {
			if c.ID == selection.Core {
				e.applyCore(c.ID)
				break
			}
		}
	}
}
func (e *Engine) refreshCores() {
	all := []CoreCapability{}
	for _, id := range []string{"xray", "sing-box", "mihomo"} {
		c := CoreCapability{ID: id, SupportedModes: coreModes(id), FullProfiles: id == "xray", ProfileSupport: coreProfileSupport(id)}
		path := e.coreBinary(id)
		if fi, err := os.Stat(path); err == nil && !fi.IsDir() {
			c.Installed = true
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			cmd := exec.CommandContext(ctx, path, coreArgs(id, "version", "", e.dir)...)
			hideCommand(cmd)
			out, err := cmd.Output()
			cancel()
			if err == nil {
				c.Available = true
				c.Version = strings.SplitN(strings.TrimSpace(string(out)), "\n", 2)[0]
			}
		}
		all = append(all, c)
	}
	e.status.Capabilities.Cores = all
	e.status.Core = e.coreID()
	e.status.Capabilities.SupportedModes = coreModes(e.coreID())
	e.status.Capabilities.FullProfiles = e.coreID() == "xray"
	e.status.Capabilities.ProfileSupport = coreProfileSupport(e.coreID())
}
func (e *Engine) applyCore(id string) {
	e.core = id
	e.binary = e.coreBinary(id)
	e.status.Core = id
	e.status.Capabilities.SupportedModes = coreModes(id)
	e.status.Capabilities.FullProfiles = id == "xray"
	e.status.Capabilities.ProfileSupport = coreProfileSupport(id)
	for _, c := range e.status.Capabilities.Cores {
		if c.ID == id {
			e.status.Available = c.Available
			e.status.Version = c.Version
			if c.Available {
				e.status.Problem = ""
				e.status.Error = ""
			} else if id != "xray" {
				e.status.Problem = "core_missing"
				if c.Installed {
					e.status.Problem = "core_start_failed"
				}
				e.status.Error = fmt.Sprintf("Ядро %s недоступно. Установите полный пакет с этим ядром или выберите другое ядро.", id)
			}
		}
	}
}
func (e *Engine) SelectCore(id string) error {
	e.op.Lock()
	defer e.op.Unlock()
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.cmd != nil || e.status.State == "running" || e.status.State == "starting" || e.status.State == "stopping" || e.restoreProxy != nil {
		return fail(409, "Перед сменой ядра остановите подключение")
	}
	if id != "xray" && id != "sing-box" && id != "mihomo" {
		return fail(400, "Неизвестное ядро")
	}
	e.refreshCores()
	for _, c := range e.status.Capabilities.Cores {
		if c.ID == id && !c.Available {
			return fail(503, "Выбранное ядро не установлено или не запускается")
		}
	}
	raw, _ := json.Marshal(object{"core": id})
	// Replace atomically so a crash never leaves a partial selection file.
	f, err := os.CreateTemp(e.dir, "core-selection-*.tmp")
	if err != nil {
		return err
	}
	path := f.Name()
	defer os.Remove(path)
	if _, err = f.Write(raw); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	if err = os.Rename(path, filepath.Join(e.dir, "core-selection.json")); err != nil {
		return err
	}
	e.applyCore(id)
	e.status.State = "stopped"
	return nil
}

func bindSubscriptionFallback(g *Group, core string, server ServerConfig) ServerConfig {
	server.RuntimeFallbackCore = ""
	if server.SubscriptionCore != "xray" || server.FullProfile || len(server.Profile) != 0 || server.SourceProfileCore != "" || (core != "sing-box" && core != "mihomo") {
		return server
	}
	for _, sub := range g.Subscriptions {
		if sub.ID == server.SubscriptionID {
			status, ok := sub.Variants[core]
			if ok && status.State == "unavailable" && status.Count == 0 {
				server.RuntimeFallbackCore = core
			}
			break
		}
	}
	return server
}

func buildCoreConfig(id string, server ServerConfig, sp, hp int, mode string) ([]byte, error) {
	if mode == "tun" && (id == "sing-box" || id == "mihomo") {
		if runtime.GOOS != "windows" {
			return nil, nativeUnsupported("TUN этого ядра пока доступен только в Windows")
		}
		raw, err := buildCoreConfig(id, server, sp, hp, "local")
		if err != nil {
			return nil, err
		}
		if id == "mihomo" && server.SourceProfileCore == "" && !server.FullProfile && len(server.Profile) == 0 {
			var config object
			if err := json.Unmarshal(raw, &config); err != nil {
				return nil, err
			}
			proxies, _ := config["proxies"].([]any)
			for _, proxy := range proxies {
				obj(proxy)["udp"] = true
			}
			raw, err = json.Marshal(config)
			if err != nil {
				return nil, err
			}
		}
		return nativeWindowsTunConfig(id, raw)
	}
	if id == "" {
		id = "xray"
	}
	standaloneFallback := server.SubscriptionCore == "xray" && !server.FullProfile && len(server.Profile) == 0 && server.SourceProfileCore == "" && server.RuntimeFallbackCore == id && (id == "sing-box" || id == "mihomo")
	if server.SubscriptionCore != "" && server.SubscriptionCore != id && !standaloneFallback {
		return nil, fail(409, "Ядро изменилось. Выберите сервер из списка для текущего ядра; при необходимости обновите подписку.")
	}
	if mode == "system" && runtime.GOOS != "windows" {
		return nil, fail(422, "Системный прокси не поддерживается на этой платформе. Выберите локальный прокси или TUN с Xray.")
	}
	if server.SourceProfileCore != "" {
		if server.SourceProfileCore != "sing-box" && server.SourceProfileCore != "mihomo" {
			return nil, fail(422, "Неизвестное ядро исходного профиля")
		}
		if id != server.SourceProfileCore {
			return nil, fail(422, "Этот профиль предназначен для "+coreName(server.SourceProfileCore)+". Выберите это ядро для подключения и проверки.")
		}
		return buildProviderNativeConfig(id, server, sp, hp, mode)
	}
	if id == "" || id == "xray" {
		return buildXrayConfig(server, sp, hp, mode)
	}
	return buildNativeCoreConfig(id, server, sp, hp, mode)
}
