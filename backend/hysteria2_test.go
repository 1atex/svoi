package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestHysteria2Import(t *testing.T) {
	for _, uri := range []string{
		"hysteria2://user:p%40ss@example.org?sni=tls.example.org#NL%20Hysteria",
		"hy2://user%3Ap%40ss@example.org:443/?sni=tls.example.org#NL%20Hysteria",
	} {
		s, err := parseServerURI(uri)
		if err != nil {
			t.Fatal(err)
		}
		var out object
		_ = json.Unmarshal(s.Outbound, &out)
		stream := obj(out["streamSettings"])
		if s.Name != "NL Hysteria" || s.Protocol != "hysteria2" || s.Port != 443 || s.Network != "hysteria" || s.Security != "tls" || obj(stream["hysteriaSettings"])["auth"] != "user:p@ss" || obj(stream["tlsSettings"])["serverName"] != "tls.example.org" {
			t.Fatalf("wrong import: %+v %s", s.ServerInfo, s.Outbound)
		}
		p, err := parseSubscription([]byte(base64.StdEncoding.EncodeToString([]byte(uri + "\ntrojan://pass@other.example:443"))))
		if err != nil || len(p.Servers) != 2 {
			t.Fatalf("mixed subscription: %v", err)
		}
	}
	s, err := parseServerURI("hy2://[2001:db8::1]:443,8443-8445?obfs=salamander&obfs-password=secret&hop-interval=10")
	if err != nil || s.Address != "2001:db8::1" || s.Port != 443 {
		t.Fatalf("IPv6/hopping: %+v %v", s, err)
	}
	var out object
	_ = json.Unmarshal(s.Outbound, &out)
	masks := obj(obj(out["streamSettings"])["finalmask"])["udp"].([]any)
	if str(obj(masks[0])["type"]) != "salamander" || str(obj(masks[1])["type"]) != "udphop" || obj(obj(masks[1])["settings"])["remotePorts"] != "443,8443-8445" {
		t.Fatalf("incorrect mask stack: %s", s.Outbound)
	}
	alias, err := parseServerURI("hysteria2://[2001:db8::1]:443?mport=443,8443-8445&obfs=salamander&obfs-password=secret&hop-interval=10")
	if err != nil || alias.ID != s.ID {
		t.Fatalf("aliases should produce identical config: %v", err)
	}
}

func TestHysteria2RejectsUnrepresentableSettings(t *testing.T) {
	for _, uri := range []string{
		"hy2://example.org:0", "hy2://example.org:65536", "hy2://example.org:443-1", "hy2://example.org:443,", "hy2://[bad]:443", "hy2://:443", "hy2://host:443/path",
		"hy2://host?insecure=1", "hy2://host?insecure=true", "hy2://host?allowInsecure=true", "hy2://host?pinSHA256=1234", "hy2://host?security=none",
		"hy2://host?obfs=gecko", "hy2://host?obfs-password=secret", "hy2://host?obfs=salamander&obfs-password=abc",
		"hy2://host:443,8443?mport=1234", "hy2://host?mport=443&ports=443", "hy2://host:443-445?hop-interval=1", "hy2://host?hop-interval=10",
		"hy2://host?sni=one&sni=two", "hy2://host?ech=invalid!!!", "hy2://host?insecure=maybe", "hy2://host?unknown=secret",
	} {
		if _, err := parseServerURI(uri); err == nil {
			t.Errorf("accepted invalid or unsupported URI: %s", uri)
		}
	}
	if _, err := parseServerURI("hy2://host?insecure=0&allowInsecure=false"); err != nil {
		t.Fatal(err)
	}
}

func TestHysteria2LibraryAndTransfer(t *testing.T) {
	a := newTestApp(t)
	token := create(t, a)
	const uri = "hy2://private-hysteria-password@example.org:443?obfs=salamander&obfs-password=private-obfs-password#HY2"
	v := expect(t, call(a, "POST", "/api/subscription/import", token, map[string]string{"content": uri + "\n" + uri}), 200)
	if len(v["servers"].([]any)) != 1 {
		t.Fatal("duplicate Hysteria2 nodes imported")
	}
	if strings.Contains(string(mustJSON(t, v)), "private-") {
		t.Fatal("public summary leaked Hysteria2 password")
	}
	code := expect(t, call(a, "POST", "/api/transfer/export", token, nil), 200)["code"].(string)
	copy, err := decodeTransfer(code)
	if err != nil || len(copy.Servers) != 1 || copy.Servers[0].Protocol != "hysteria2" {
		t.Fatalf("transfer lost node: %v", err)
	}
	if !bytes.Equal(copy.Servers[0].Outbound, a.state.Groups[0].Servers[0].Outbound) {
		t.Fatal("transfer altered Hysteria2 parameters")
	}
	restored, err := openApp(a.path)
	if err != nil {
		t.Fatalf("persistence failed: %v", err)
	}
	var saved, original object
	_ = json.Unmarshal(restored.state.Groups[0].Servers[0].Outbound, &saved)
	_ = json.Unmarshal(copy.Servers[0].Outbound, &original)
	if !reflect.DeepEqual(saved, original) {
		t.Fatal("persisted Hysteria2 config changed")
	}
}

func TestHysteria2ConfigsWithPackagedXray(t *testing.T) {
	binaryPath := testCore(t)
	for _, uri := range []string{
		"hy2://test-password@example.org",
		"hysteria2://user:pass@[2001:db8::1]:8443?sni=example.org&alpn=h3&obfs=salamander&obfs-password=obfs-secret",
		"hy2://test-password@example.org:443,8443-8445?obfs=salamander&obfs-password=obfs-secret&hop-interval=5",
	} {
		s, err := parseServerURI(uri)
		if err != nil {
			t.Fatal(err)
		}
		for _, mode := range []string{"local", "system", "tun"} {
			s.RuntimeApps = &AppRouting{Mode: "include", Processes: []string{"browser.exe"}}
			config, err := buildXrayConfig(s, 10808, 10809, mode)
			if err != nil {
				t.Fatal(err)
			}
			file := filepath.Join(t.TempDir(), "config.json")
			if err := os.WriteFile(file, config, 0600); err != nil {
				t.Fatal(err)
			}
			cmd := exec.Command(binaryPath, "run", "-test", "-c", file)
			hideCommand(cmd)
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("core rejected %s: %s", mode, out)
			}
		}
	}
}

func hysteriaTestCertificate(t *testing.T) (string, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "localhost"}, DNSNames: []string{"localhost"}, IPAddresses: []net.IP{net.ParseIP("127.0.0.1")}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, BasicConstraintsValid: true, IsCA: true}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})), string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}))
}

func TestHysteria2RoundTrip(t *testing.T) {
	core := testCore(t)
	cert, key := hysteriaTestCertificate(t)
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusNoContent) }))
	defer target.Close()
	portSocket, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := portSocket.LocalAddr().(*net.UDPAddr).Port
	portSocket.Close()
	const password = "svoi-hysteria-roundtrip-secret"
	for _, obfuscate := range []bool{false, true} {
		t.Run(strconv.FormatBool(obfuscate), func(t *testing.T) {
			stream := object{"network": "hysteria", "security": "tls", "hysteriaSettings": object{"version": 2}, "tlsSettings": object{"alpn": []string{"h3"}, "certificates": []any{object{"certificate": strings.Split(cert, "\n"), "key": strings.Split(key, "\n")}}}}
			suffix := "?sni=localhost"
			if obfuscate {
				stream["finalmask"] = object{"udp": []any{object{"type": "salamander", "settings": object{"password": "obfs-secret"}}}}
				suffix += "&obfs=salamander&obfs-password=obfs-secret"
			}
			config := object{"log": object{"loglevel": "warning"}, "inbounds": []any{object{"listen": "127.0.0.1", "port": port, "protocol": "hysteria", "settings": object{"version": 2, "users": []any{object{"auth": password}}}, "streamSettings": stream}}, "outbounds": []any{object{"protocol": "freedom", "settings": object{"finalRules": []any{object{"action": "allow", "ip": []string{"127.0.0.1"}}}}}}}
			file := filepath.Join(t.TempDir(), "server.json")
			data, _ := json.Marshal(config)
			if err := os.WriteFile(file, data, 0600); err != nil {
				t.Fatal(err)
			}
			logs := &Engine{}
			cmd := exec.Command(core, "run", "-c", file)
			hideCommand(cmd)
			cmd.Stdout, cmd.Stderr = logs, logs
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			defer func() {
				_ = cmd.Process.Kill()
				_ = cmd.Wait()
				if t.Failed() {
					t.Log(logs.Status().Logs)
				}
			}()
			deadline := time.Now().Add(5 * time.Second)
			for {
				logs.mu.Lock()
				ready := logs.coreStarted
				logs.mu.Unlock()
				if ready {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("Hysteria2 server did not start")
				}
				time.Sleep(20 * time.Millisecond)
			}
			s, err := parseServerURI("hy2://" + password + "@127.0.0.1:" + strconv.Itoa(port) + suffix)
			if err != nil {
				t.Fatal(err)
			}
			var out object
			_ = json.Unmarshal(s.Outbound, &out)
			obj(obj(out["streamSettings"])["tlsSettings"])["certificates"] = []any{object{"certificate": strings.Split(cert, "\n"), "usage": "verify"}}
			s.Outbound, _ = json.Marshal(out)
			engine, err := newEngine(core, t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer engine.Stop()
			engine.checkURL = target.URL
			for cycle := 0; cycle < 2; cycle++ {
				if err := engine.Start(s, "local"); err != nil {
					t.Fatalf("start: %v %v", err, engine.Status().Logs)
				}
				ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
				_, err := engine.Check(ctx)
				cancel()
				if err != nil {
					t.Fatalf("HTTP through Hysteria2: %v %v", err, engine.Status().Logs)
				}
				testHysteriaUDP(t, engine.Status().SocksPort)
				if err := engine.Stop(); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := probeServer(context.Background(), engine, s); err != nil {
				t.Fatalf("probe: %v", err)
			}
			obj(obj(out["streamSettings"])["hysteriaSettings"])["auth"] = "wrong-password"
			s.Outbound, _ = json.Marshal(out)
			if _, err := probeServer(context.Background(), engine, s); err == nil {
				t.Fatal("wrong auth passed probe")
			}
		})
	}
}

func testHysteriaUDP(t *testing.T, socksPort int) {
	t.Helper()
	echo, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		buf := make([]byte, 1024)
		n, peer, err := echo.ReadFrom(buf)
		if err == nil {
			_, _ = echo.WriteTo(buf[:n], peer)
		}
	}()
	control, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(socksPort)), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer control.Close()
	_ = control.SetDeadline(time.Now().Add(4 * time.Second))
	_, _ = control.Write([]byte{5, 1, 0})
	reply := make([]byte, 2)
	if _, err = io.ReadFull(control, reply); err != nil || !bytes.Equal(reply, []byte{5, 0}) {
		t.Fatal("SOCKS negotiation", err)
	}
	_, _ = control.Write([]byte{5, 3, 0, 1, 127, 0, 0, 1, 0, 0})
	response := make([]byte, 10)
	if _, err = io.ReadFull(control, response); err != nil || response[1] != 0 || response[3] != 1 {
		t.Fatal("UDP association", err)
	}
	udp, err := net.DialUDP("udp", nil, &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: int(binary.BigEndian.Uint16(response[8:]))})
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	_ = udp.SetDeadline(time.Now().Add(4 * time.Second))
	packet := []byte{0, 0, 0, 1, 127, 0, 0, 1, 0, 0}
	binary.BigEndian.PutUint16(packet[8:], uint16(echo.LocalAddr().(*net.UDPAddr).Port))
	packet = append(packet, []byte("hysteria2-udp-echo")...)
	if _, err = udp.Write(packet); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 1024)
	n, err := udp.Read(buf)
	if err != nil || n < 10 || !bytes.Equal(buf[10:n], packet[10:]) {
		t.Fatalf("UDP relay failed: %v", err)
	}
}
