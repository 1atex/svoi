package backend

import (
	"net"
	"net/http/httptest"
	"strconv"
	"testing"
)

func TestTCPProbeDoesNotStartXrayOrChangeConnection(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		conn, err := listener.Accept()
		if err == nil {
			conn.Close()
		}
	}()
	host, port, _ := net.SplitHostPort(listener.Addr().String())
	n, _ := strconv.Atoi(port)
	a := newTestApp(t)
	token := create(t, a)
	a.state.Groups[0].Servers = []ServerConfig{{ServerInfo: ServerInfo{ID: "tcp-test", Address: host, Port: n}}}
	a.engine = &Engine{status: EngineStatus{State: "stopped"}}
	r := httptest.NewRequest("POST", "/api/servers/tcp-test/tcp", nil)
	r.RemoteAddr = "127.0.0.1:1234"
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	if err := a.serverToolsAPI(w, r); err != nil {
		t.Fatal(err)
	}
	expect(t, w, 200)
	if a.engine.cmd != nil || a.engine.status.Checked {
		t.Fatal("TCP test changed VPN state")
	}
	a.state.Groups[0].Servers[0].FullProfile = true
	if a.serverToolsAPI(httptest.NewRecorder(), r) == nil {
		t.Fatal("full profile incorrectly reduced to one address")
	}
	a.state.Groups[0].Servers[0].FullProfile = false
	a.state.Groups[0].Servers[0].Protocol = "hysteria2"
	if a.serverToolsAPI(httptest.NewRecorder(), r) == nil {
		t.Fatal("UDP Hysteria2 incorrectly offered a TCP check")
	}
}
