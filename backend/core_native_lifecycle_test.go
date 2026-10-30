package main

import (
	"encoding/json"
	"runtime"
	"strings"
	"testing"
)

func TestNativeTunStandaloneMihomoCarriesUDP(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("native TUN is currently Windows-only")
	}
	server := nativeTestServer(t)
	raw, err := buildCoreConfig("mihomo", server, 21081, 21082, "tun")
	if err != nil {
		t.Fatal(err)
	}
	var config object
	_ = json.Unmarshal(raw, &config)
	for _, proxy := range config["proxies"].([]any) {
		if obj(proxy)["udp"] != true {
			t.Fatal("standalone TUN traffic could fall through proxy on UDP")
		}
	}
	if nativeTunDeviceFromConfig("mihomo", raw) == "" {
		t.Fatal("native TUN lacks an owned interface")
	}
}

func TestNativeTunReadinessWaitsForSuccessfulStartup(t *testing.T) {
	sb := &Engine{core: "sing-box", tunDevice: "SVOI-SB-fixture"}
	_, _ = sb.Write([]byte("INFO inbound/tun: started at SVOI-SB-fixture\nINFO inbound/mixed: listening\n"))
	if sb.coreStarted || sb.tunReady {
		t.Fatal("inbound alone reported complete service startup")
	}
	_, _ = sb.Write([]byte("\x1b[31mFATAL\x1b[0m start dns-transport: unavailable\n"))
	if sb.coreStarted || sb.tunReady {
		t.Fatal("DNS failure reported as ready")
	}
	if strings.Contains(strings.Join(sb.status.Logs, ""), "\x1b") {
		t.Fatal("terminal escape sequences exposed in UI logs")
	}
	_, _ = sb.Write([]byte("INFO sing-box start"))
	_, _ = sb.Write([]byte("ed (0.21s)\n"))
	if !sb.coreStarted || !sb.tunReady {
		t.Fatal("successful fragmented startup marker not recognized")
	}

	mh := &Engine{core: "mihomo", tunDevice: "SVOI-MH-fixture"}
	_, _ = mh.Write([]byte("INFO SOCKS proxy listening\nINFO [TUN] Tun adapter listening at: another-device\n"))
	if mh.tunReady {
		t.Fatal("foreign adapter or proxy accepted as TUN")
	}
	_, _ = mh.Write([]byte("ERROR Start TUN listening error: access denied\n"))
	if !mh.tunError || mh.tunReady {
		t.Fatal("Mihomo swallowed TUN error not detected")
	}
	_, _ = mh.Write([]byte("INFO [TUN] Tun adapter listening at: SVOI-MH-fixture\n"))
	if !mh.tunReady || !mh.tunError {
		t.Fatal("later success must not erase startup error")
	}
}

func TestCoreStartupLogsRetainDataPlane(t *testing.T) {
	raw := []byte(`{"log":{"level":"warn"},"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}`)
	data, err := coreStartupConfig("sing-box", raw)
	if err != nil {
		t.Fatal(err)
	}
	var result object
	_ = json.Unmarshal(data, &result)
	if obj(result["log"])["level"] != "info" || obj(result["route"])["final"] != "direct" || len(result["outbounds"].([]any)) != 1 {
		t.Fatal("startup logging changed routing")
	}
	if nativeTunInterfaceReady("SVOI-nonexistent-test-interface") {
		t.Fatal("nonexistent adapter accepted")
	}
	if err := waitNativeTunStopped("SVOI-nonexistent-test-interface"); err != nil {
		t.Fatal(err)
	}
}
