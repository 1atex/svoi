package main

import (
	"bytes"
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestTunDNSPreservesProviderResolver(t *testing.T) {
	for _, explicit := range []bool{false, true} {
		dns := object{"queryStrategy": "UseIPv4", "servers": []string{"1.1.1.1"}}
		if explicit {
			dns["tag"] = "provider-dns"
		}
		config := object{"dns": dns, "outbounds": []any{object{"tag": "svoi-dns-out", "protocol": "blackhole"}}, "routing": object{"rules": []any{object{"inboundTag": []any{"tun"}, "balancerTag": "provider"}, object{"inboundTag": []any{"loop"}, "outboundTag": "fallback"}}}}
		configureTunDNS(config, "tun")
		rules := obj(config["routing"])["rules"].([]any)
		if obj(rules[0])["outboundTag"] == "svoi-dns-out" {
			t.Fatal("DNS tag collision")
		}
		if dns["queryStrategy"] != "UseIPv4" || !reflect.DeepEqual(dns["servers"], []string{"1.1.1.1"}) {
			t.Fatal("provider DNS changed")
		}
		if !reflect.DeepEqual(obj(rules[2])["inboundTag"], []any{"loop"}) {
			t.Fatal("loopback routing changed")
		}
		entry := obj(rules[1])["inboundTag"].([]any)
		if explicit {
			if dns["tag"] != "provider-dns" || len(entry) != 1 {
				t.Fatal("explicit DNS routing changed")
			}
		} else if len(entry) != 2 || entry[1] != dns["tag"] {
			t.Fatal("resolver bypasses profile balancer")
		}
	}
}

func TestTunDNSWithRealXray(t *testing.T) {
	listener, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := listener.LocalAddr().String()
	port := listener.LocalAddr().(*net.UDPAddr).Port
	listener.Close()
	config := object{"log": object{"loglevel": "warning"}, "inbounds": []any{object{"tag": "tun-test", "protocol": "dokodemo-door", "listen": "127.0.0.1", "port": port, "settings": object{"address": "1.1.1.1", "port": 53, "network": "udp"}}}, "outbounds": []any{object{"protocol": "blackhole"}}, "dns": object{"queryStrategy": "UseIPv4", "hosts": object{"svoi.test": "192.0.2.42"}}}
	configureTunDNS(config, "tun-test")
	file := filepath.Join(t.TempDir(), "dns.json")
	data, _ := json.Marshal(config)
	if err := os.WriteFile(file, data, 0600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(testCore(t), "run", "-c", file)
	hideCommand(cmd)
	var logs bytes.Buffer
	cmd.Stdout, cmd.Stderr = &logs, &logs
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		cmd.Process.Kill()
		cmd.Wait()
		if t.Failed() {
			t.Log(logs.String())
		}
	}()
	conn, err := net.Dial("udp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	query := []byte{0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 4, 's', 'v', 'o', 'i', 4, 't', 'e', 's', 't', 0, 0, 1, 0, 1}
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		conn.SetDeadline(time.Now().Add(200 * time.Millisecond))
		conn.Write(query)
		answer := make([]byte, 512)
		n, err := conn.Read(answer)
		if err != nil {
			continue
		}
		if n < 12 || answer[0] != 0x12 || answer[1] != 0x34 || answer[3]&15 != 0 || !bytes.Contains(answer[:n], []byte{192, 0, 2, 42}) {
			t.Fatal("DNS response did not use profile hosts")
		}
		return
	}
	t.Fatal("DNS never reached the profile resolver")
}
