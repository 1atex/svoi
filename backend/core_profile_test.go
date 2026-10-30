package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

func nativeProfileTestSource(t *testing.T) object {
	t.Helper()
	s, err := parseServerURI("vless://" + nativeTestUUID + "@127.0.0.1:12345?security=none")
	if err != nil {
		t.Fatal(err)
	}
	var out object
	json.Unmarshal(s.Outbound, &out)
	out["tag"] = "proxy,with(parser)characters"
	return object{"outbounds": []any{out, object{"protocol": "freedom", "tag": "direct"}, object{"protocol": "blackhole", "tag": "block"}}, "routing": object{"domainStrategy": "AsIs", "rules": []any{}}}
}
func nativeProfileTestServer(t *testing.T, profile object) ServerConfig {
	t.Helper()
	raw, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	return ServerConfig{ServerInfo: ServerInfo{FullProfile: true}, Profile: raw}
}

func TestNativeProfileOrderedGraphAndRuleLogic(t *testing.T) {
	for _, id := range []string{"sing-box", "mihomo"} {
		t.Run(id, func(t *testing.T) {
			profile := nativeProfileTestSource(t)
			profile["log"] = object{"loglevel": "debug"}
			obj(profile["routing"])["rules"] = []any{
				object{"type": "field", "domain": []string{"full:first.test", "domain:example.test", "keyword:needle"}, "ip": []string{"127.0.0.1", "::1/128"}, "network": "tcp,udp", "port": "80,443,1000-2000", "outboundTag": "block"},
				object{"ip": []string{"127.0.0.0/8"}, "outboundTag": "direct"},
			}
			server := nativeProfileTestServer(t, profile)
			before := append([]byte(nil), server.Profile...)
			raw, err := buildNativeProfileConfig(id, server, 21081, 21082, "local")
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(before, server.Profile) {
				t.Fatal("source profile mutated")
			}
			var config object
			json.Unmarshal(raw, &config)
			if id == "sing-box" {
				route := obj(config["route"])
				rules := route["rules"].([]any)
				first := obj(rules[0])
				if route["final"] != "svoi-node-0" || first["type"] != "logical" || first["mode"] != "and" || len(first["rules"].([]any)) != 4 || first["action"] != "reject" {
					t.Fatal(string(raw))
				}
				if obj(first["rules"].([]any)[0])["mode"] != "or" {
					t.Fatal("domain selector OR lost")
				}
			} else {
				rules := config["rules"].([]any)
				if !strings.HasPrefix(str(rules[0]), "AND,((OR,") || !strings.Contains(str(rules[0]), "no-resolve") || rules[len(rules)-1] != "MATCH,svoi-node-0" {
					t.Fatal(string(raw))
				}
				if obj(config["proxies"].([]any)[0])["udp"] != true {
					t.Fatal("Mihomo UDP rule fallthrough enabled")
				}
			}
		})
	}
}

func TestNativeProfileRejectsUntranslatedSemantics(t *testing.T) {
	edits := map[string]func(object){
		"dns": func(p object) { p["dns"] = object{} }, "policy": func(p object) { p["policy"] = object{} }, "stats": func(p object) { p["stats"] = object{} }, "observatory": func(p object) { p["observatory"] = object{} },
		"balancers": func(p object) { obj(p["routing"])["balancers"] = []any{} }, "script": func(p object) { obj(p["routing"])["script"] = "" },
		"dns-resolution-routing": func(p object) { obj(p["routing"])["domainStrategy"] = "IPIfNonMatch" },
		"sniffing": func(p object) {
			p["inbounds"] = []any{object{"protocol": "socks", "sniffing": object{"enabled": true}}}
		},
		"inbound-auth": func(p object) {
			p["inbounds"] = []any{object{"protocol": "socks", "settings": object{"auth": "password"}}}
		},
		"freedom-redirect": func(p object) { obj(p["outbounds"].([]any)[1])["settings"] = object{"redirect": "127.0.0.1:1"} },
		"blackhole-response": func(p object) {
			obj(p["outbounds"].([]any)[2])["settings"] = object{"response": object{"type": "http"}}
		},
		"chain":           func(p object) { obj(p["outbounds"].([]any)[0])["proxySettings"] = object{"tag": "direct"} },
		"duplicate-tags":  func(p object) { obj(p["outbounds"].([]any)[1])["tag"] = obj(p["outbounds"].([]any)[0])["tag"] },
		"empty-outbounds": func(p object) { p["outbounds"] = []any{} },
	}
	ruleEdits := map[string]object{
		"geosite": {"domain": []string{"geosite:private"}}, "regex": {"domain": []string{"regexp:.*"}}, "geoip": {"ip": []string{"geoip:private"}},
		"inboundTag": {"inboundTag": []string{"socks-in"}}, "source": {"source": []string{"127.0.0.1"}}, "protocol": {"protocol": []string{"tls"}},
		"unknown-target": {"network": "tcp", "outboundTag": "missing"}, "empty-domain": {"domain": []string{}}, "bad-network": {"network": "tcp,icmp"}, "bad-port": {"port": "80,65536"}, "reversed-range": {"port": "100-1"}, "empty-rule": {},
	}
	for name, rule := range ruleEdits {
		rule := rule
		edits["rule-"+name] = func(p object) {
			r := object{"outboundTag": "direct"}
			for k, v := range rule {
				r[k] = v
			}
			obj(p["routing"])["rules"] = []any{r}
		}
	}
	for _, id := range []string{"sing-box", "mihomo"} {
		for name, edit := range edits {
			t.Run(id+"/"+name, func(t *testing.T) {
				p := nativeProfileTestSource(t)
				edit(p)
				_, err := buildNativeProfileConfig(id, nativeProfileTestServer(t, p), 21081, 21082, "local")
				var api apiError
				if !errors.As(err, &api) || api.status != 422 {
					t.Fatal("semantic loss accepted", err)
				}
			})
		}
	}
	for _, profile := range []json.RawMessage{nil, json.RawMessage(`null`), json.RawMessage(`{"outbounds":[]}`)} {
		if _, err := buildNativeProfileConfig("sing-box", ServerConfig{ServerInfo: ServerInfo{FullProfile: true}, Profile: profile}, 21081, 21082, "local"); err == nil {
			t.Fatal("empty profile accepted")
		}
	}
}

func TestNativeProfileBundledCoreValidation(t *testing.T) {
	for _, id := range []string{"sing-box", "mihomo"} {
		t.Run(id, func(t *testing.T) {
			binaryPath := testNativeCore(t, id)
			profile := nativeProfileTestSource(t)
			obj(profile["routing"])["rules"] = []any{
				object{"domain": []string{"full:a.test", "domain:example.test", "keyword:needle"}, "ip": []string{"127.0.0.0/8", "::1/128"}, "network": "tcp,udp", "port": "80,443,1000-2000", "outboundTag": "block"},
				object{"ip": []string{"127.0.0.1"}, "outboundTag": "direct"},
			}
			for _, blockDefault := range []bool{false, true} {
				if blockDefault {
					outs := profile["outbounds"].([]any)
					outs[0], outs[2] = outs[2], outs[0]
				}
				raw, err := buildNativeProfileConfig(id, nativeProfileTestServer(t, profile), 21081, 21082, "local")
				if err != nil {
					t.Fatal(err)
				}
				dir := t.TempDir()
				path := filepath.Join(dir, "config.json")
				if err = os.WriteFile(path, raw, 0600); err != nil {
					t.Fatal(err)
				}
				ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
				cmd := exec.CommandContext(ctx, binaryPath, coreArgs(id, "check", path, dir)...)
				hideCommand(cmd)
				output, err := cmd.CombinedOutput()
				cancel()
				if err != nil {
					t.Fatalf("core check: %v %s\n%s", err, output, raw)
				}
			}
		})
	}
}

func TestNativeProfileOrderedLoopbackTraffic(t *testing.T) {
	portA, hitsA := nativeVLESSFixture(t)
	portB, hitsB := nativeVLESSFixture(t)
	targets := []*httptest.Server{}
	for i := 0; i < 5; i++ {
		target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "profile-routing-loopback") }))
		targets = append(targets, target)
		defer target.Close()
	}
	port := func(index int) string { u, _ := url.Parse(targets[index].URL); return u.Port() }
	for _, id := range []string{"sing-box", "mihomo"} {
		t.Run(id, func(t *testing.T) {
			p := nativeProfileTestSource(t)
			first := obj(p["outbounds"].([]any)[0])
			first["tag"] = "a"
			firstObject(obj(first["settings"])["vnext"])["port"] = portA
			secondRaw, _ := json.Marshal(first)
			var second object
			json.Unmarshal(secondRaw, &second)
			second["tag"] = "b"
			firstObject(obj(second["settings"])["vnext"])["port"] = portB
			p["outbounds"] = []any{first, second, object{"protocol": "freedom", "tag": "direct"}, object{"protocol": "blackhole", "tag": "block"}}
			obj(p["routing"])["rules"] = []any{
				// The destination is a literal IP, so domain AND IP must NOT match.
				object{"domain": []string{"full:not-a-target.invalid"}, "ip": []string{"127.0.0.0/8"}, "outboundTag": "block"},
				object{"network": "tcp", "port": port(0), "outboundTag": "b"},
				object{"network": "tcp", "port": port(0), "outboundTag": "block"},
				object{"port": port(1), "outboundTag": "direct"},
				object{"port": port(3), "outboundTag": "block"},
				// AsIs must not resolve localhost to make this IP rule match.
				object{"ip": []string{"127.0.0.0/8"}, "port": port(4), "outboundTag": "block"},
				object{"domain": []string{"full:no-match.invalid", "full:localhost"}, "port": port(4), "outboundTag": "direct"},
			}
			e := nativeTestEngine(t, id)
			if err := e.Start(nativeProfileTestServer(t, p), "local"); err != nil {
				t.Fatal(err, e.Status().Logs)
			}
			proxy, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", e.Status().HTTPPort))
			transport := &http.Transport{Proxy: http.ProxyURL(proxy), DisableKeepAlives: true}
			defer transport.CloseIdleConnections()
			client := &http.Client{Transport: transport, Timeout: 3 * time.Second}
			a, b := hitsA.Load(), hitsB.Load()
			get := func(index int) error {
				response, err := client.Get(targets[index].URL)
				if err != nil {
					return err
				}
				defer response.Body.Close()
				body, err := io.ReadAll(response.Body)
				if string(body) != "profile-routing-loopback" {
					return fmt.Errorf("unexpected loopback payload")
				}
				return err
			}
			if err := get(0); err != nil {
				t.Fatal(err, e.Status().Logs)
			}
			if hitsA.Load() != a || hitsB.Load() != b+1 {
				t.Fatal("ordered rule/AND behavior lost", hitsA.Load()-a, hitsB.Load()-b)
			}
			if err := get(1); err != nil {
				t.Fatal(err)
			}
			if hitsA.Load() != a || hitsB.Load() != b+1 {
				t.Fatal("direct rule used proxy")
			}
			if err := get(2); err != nil {
				t.Fatal(err)
			}
			if hitsA.Load() != a+1 || hitsB.Load() != b+1 {
				t.Fatal("default did not use first outbound")
			}
			if err := get(3); err == nil {
				t.Fatal("blocked destination reached target")
			}
			if hitsA.Load() != a+1 || hitsB.Load() != b+1 {
				t.Fatal("block rule leaked to proxy")
			}
			response, err := client.Get(strings.Replace(targets[4].URL, "127.0.0.1", "localhost", 1))
			if err != nil {
				t.Fatal("AsIs/domain OR rule changed", err, e.Status().Logs)
			}
			body, err := io.ReadAll(response.Body)
			response.Body.Close()
			if err != nil || string(body) != "profile-routing-loopback" || hitsA.Load() != a+1 || hitsB.Load() != b+1 {
				t.Fatal("domain OR/direct route changed", err, response.StatusCode, string(body), e.Status().Logs)
			}
		})
	}
}

// Return errors rather than failing directly, so bad proxy credentials must also
// fail the same UDP exchange. This catches Mihomo's silent DIRECT UDP fallback.
func nativeProfileUDPExchange(socksPort int) error {
	echo, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	defer echo.Close()
	go func() {
		buffer := make([]byte, 1024)
		n, peer, err := echo.ReadFrom(buffer)
		if err == nil {
			echo.WriteTo(buffer[:n], peer)
		}
	}()
	control, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(socksPort)), time.Second)
	if err != nil {
		return err
	}
	defer control.Close()
	control.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err = control.Write([]byte{5, 1, 0}); err != nil {
		return err
	}
	reply := make([]byte, 2)
	if _, err = io.ReadFull(control, reply); err != nil || !bytes.Equal(reply, []byte{5, 0}) {
		return fmt.Errorf("SOCKS negotiation: %v", err)
	}
	if _, err = control.Write([]byte{5, 3, 0, 1, 127, 0, 0, 1, 0, 0}); err != nil {
		return err
	}
	response := make([]byte, 10)
	if _, err = io.ReadFull(control, response); err != nil || response[1] != 0 || response[3] != 1 {
		return fmt.Errorf("UDP association: %v", err)
	}
	udp, err := net.DialUDP("udp", nil, &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: int(binary.BigEndian.Uint16(response[8:]))})
	if err != nil {
		return err
	}
	defer udp.Close()
	udp.SetDeadline(time.Now().Add(2 * time.Second))
	packet := []byte{0, 0, 0, 1, 127, 0, 0, 1, 0, 0}
	binary.BigEndian.PutUint16(packet[8:], uint16(echo.LocalAddr().(*net.UDPAddr).Port))
	packet = append(packet, []byte("native-full-profile-udp")...)
	if _, err = udp.Write(packet); err != nil {
		return err
	}
	buffer := make([]byte, 1024)
	n, err := udp.Read(buffer)
	if err != nil {
		return err
	}
	if n < 10 || !bytes.Equal(buffer[10:n], packet[10:]) {
		return fmt.Errorf("UDP payload mismatch")
	}
	return nil
}

func TestNativeProfileProxyUDPHasNoDirectFallback(t *testing.T) {
	core := testCore(t)
	listener, port, err := reservePort()
	if err != nil {
		t.Fatal(err)
	}
	listener.Close()
	serverConfig := object{"log": object{"loglevel": "warning"}, "inbounds": []any{object{"listen": "127.0.0.1", "port": port, "protocol": "vless", "settings": object{"clients": []any{object{"id": nativeTestUUID}}, "decryption": "none"}}}, "outbounds": []any{object{"protocol": "freedom", "settings": object{"finalRules": []any{object{"action": "allow", "ip": []string{"127.0.0.1"}}}}}}}
	path := filepath.Join(t.TempDir(), "udp-vless-server.json")
	if err = os.WriteFile(path, mustJSON(t, serverConfig), 0600); err != nil {
		t.Fatal(err)
	}
	logs := &Engine{}
	cmd := exec.Command(core, "run", "-c", path)
	hideCommand(cmd)
	cmd.Stdout, cmd.Stderr = logs, logs
	if err = cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { cmd.Process.Kill(); cmd.Wait() }()
	deadline := time.Now().Add(5 * time.Second)
	for {
		c, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), 50*time.Millisecond)
		if err == nil {
			c.Close()
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("VLESS UDP fixture did not start", logs.Status().Logs)
		}
		time.Sleep(20 * time.Millisecond)
	}
	for _, id := range []string{"sing-box", "mihomo"} {
		t.Run(id, func(t *testing.T) {
			p := nativeProfileTestSource(t)
			out := obj(p["outbounds"].([]any)[0])
			firstObject(obj(out["settings"])["vnext"])["port"] = port
			e := nativeTestEngine(t, id)
			for _, valid := range []bool{true, false} {
				if !valid {
					firstObject(firstObject(obj(out["settings"])["vnext"])["users"])["id"] = "11111111-1111-4111-8111-111111111111"
				}
				if err := e.Start(nativeProfileTestServer(t, p), "local"); err != nil {
					t.Fatal(err, e.Status().Logs)
				}
				err := nativeProfileUDPExchange(e.Status().SocksPort)
				if (err == nil) != valid {
					t.Fatal("UDP proxy credentials/fallback failure", valid, err, e.Status().Logs)
				}
				if err := e.Stop(); err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}

func TestNativeProfileDomainAndIPAreSeparateANDConditions(t *testing.T) {
	conditions, err := nativeProfileRule(object{"domain": []any{"full:example.test"}, "ip": []any{"127.0.0.1"}, "outboundTag": "direct"})
	if err != nil {
		t.Fatal(err)
	}
	got := nativeProfileSingRule(conditions, nativeProfileTarget{name: "direct"})
	want := object{"type": "logical", "mode": "and", "rules": []any{object{"domain": []string{"example.test"}}, object{"ip_cidr": []string{"127.0.0.1/32"}}}, "action": "route", "outbound": "direct"}
	if !reflect.DeepEqual(got, want) {
		t.Fatal(got)
	}
}
