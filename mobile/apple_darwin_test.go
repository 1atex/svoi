package mobile

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestApplePacketFlowFramingAndReconnect(t *testing.T) {
	echo, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		data := make([]byte, 2048)
		for {
			n, remote, err := echo.ReadFromUDP(data)
			if err != nil {
				return
			}
			_, _ = echo.WriteToUDP(data[:n], remote)
		}
	}()
	port := echo.LocalAddr().(*net.UDPAddr).Port
	for cycle := 0; cycle < 5; cycle++ {
		t.Run(fmt.Sprint(cycle), func(t *testing.T) {
			pair, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
			if err != nil {
				t.Fatal(err)
			}
			defer unix.Close(pair[0])
			if err := unix.SetNonblock(pair[1], true); err != nil {
				t.Fatal(err)
			}
			flow := os.NewFile(uintptr(pair[1]), "packet-flow")
			defer flow.Close()
			config := `{"log":{"loglevel":"none"},"inbounds":[{"protocol":"tun","tag":"svoi-tun","settings":{"name":"SVOI","mtu":1500}}],"outbounds":[{"protocol":"freedom","tag":"direct"}]}`
			if err := StartApple(config, int32(pair[0]), t.TempDir()); err != nil {
				t.Fatal(err)
			}
			defer Stop()
			payload := []byte(fmt.Sprintf("SVOI-PACKET-FLOW-%d", cycle))
			packet := appleUDPFrame(uint16(41000+cycle), uint16(port), payload)
			if _, err := flow.Write(packet); err != nil {
				t.Fatal(err)
			}
			if err := flow.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
				t.Fatal(err)
			}
			response := make([]byte, 65540)
			n, err := flow.Read(response)
			if err != nil {
				t.Fatal(err)
			}
			if n < 32 || response[3] != unix.AF_INET {
				t.Fatal("invalid utun frame", n)
			}
			header := int(response[4]&15) * 4
			if !bytes.Equal(response[4+header+8:n], payload) {
				t.Fatalf("UDP payload changed: %x", response[:n])
			}
			started := time.Now()
			if err := Stop(); err != nil {
				t.Fatal(err)
			}
			if time.Since(started) > 2*time.Second {
				t.Fatal("shutdown took more than two seconds")
			}
		})
	}
}

func appleUDPFrame(source, destination uint16, payload []byte) []byte {
	packet := make([]byte, 4+20+8+len(payload))
	packet[3] = unix.AF_INET
	ip := packet[4:24]
	ip[0], ip[8], ip[9] = 0x45, 64, 17
	binary.BigEndian.PutUint16(ip[2:4], uint16(len(packet)-4))
	copy(ip[12:16], []byte{172, 31, 255, 1})
	copy(ip[16:20], []byte{127, 0, 0, 1})
	var checksum uint32
	for offset := 0; offset < 20; offset += 2 {
		checksum += uint32(binary.BigEndian.Uint16(ip[offset : offset+2]))
	}
	for checksum > 65535 {
		checksum = checksum&65535 + checksum>>16
	}
	binary.BigEndian.PutUint16(ip[10:12], ^uint16(checksum))
	udp := packet[24:]
	binary.BigEndian.PutUint16(udp[0:2], source)
	binary.BigEndian.PutUint16(udp[2:4], destination)
	binary.BigEndian.PutUint16(udp[4:6], uint16(len(udp)))
	copy(udp[8:], payload)
	return packet
}
