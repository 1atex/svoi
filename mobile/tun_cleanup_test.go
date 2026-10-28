package mobile

import (
	"context"
	"encoding/binary"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/proxy/tun"
	"io"
	"net"
	"testing"
	"time"
)

type cleanupTun struct{}

func (cleanupTun) Start() error                      { return nil }
func (cleanupTun) Close() error                      { return nil }
func (cleanupTun) Name() (string, error)             { return "test", nil }
func (cleanupTun) Index() (int, error)               { return 1, nil }
func (cleanupTun) ReadPacket([]byte) ([]byte, error) { return nil, io.EOF }
func (cleanupTun) WritePacket([]byte, []byte) error  { return nil }

type cleanupHandler struct {
	conn chan net.Conn
	done chan struct{}
}

func (h cleanupHandler) HandleConnection(c net.Conn, _ xnet.Destination) {
	h.conn <- c
	io.Copy(io.Discard, c)
	c.Close()
	close(h.done)
}
func TestTUNStackCloseUnblocksUDP(t *testing.T) {
	handler := cleanupHandler{make(chan net.Conn, 1), make(chan struct{})}
	stack, err := tun.NewStack(context.Background(), tun.StackOptions{Tun: cleanupTun{}, MTU: 1500, IdleTimeout: time.Minute}, handler)
	if err != nil {
		t.Fatal(err)
	}
	defer stack.Close()
	packet := make([]byte, 29)
	packet[0] = 0x45
	binary.BigEndian.PutUint16(packet[2:4], 29)
	packet[8] = 64
	packet[9] = 17
	copy(packet[12:16], []byte{10, 0, 0, 1})
	copy(packet[16:20], []byte{8, 8, 8, 8})
	binary.BigEndian.PutUint16(packet[20:22], 1234)
	binary.BigEndian.PutUint16(packet[22:24], 53)
	binary.BigEndian.PutUint16(packet[24:26], 9)
	packet[28] = 1
	stack.Input(packet)
	var conn net.Conn
	select {
	case conn = <-handler.conn:
	case <-time.After(time.Second):
		t.Fatal("UDP flow not created")
	}
	defer conn.Close()
	stack.Close()
	select {
	case <-handler.done:
	case <-time.After(200 * time.Millisecond):
		t.Fatal("UDP reader survived TUN stack shutdown")
	}
}
