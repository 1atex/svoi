package main

import (
	"encoding/binary"
	"reflect"
	"testing"
)

func TestLinuxTunOverridesDefaultWithoutChangingIt(t *testing.T) {
	settings := obj(tunInbound("test")["settings"])
	if !reflect.DeepEqual(settings["autoSystemRoutingTable"], []string{"0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"}) {
		t.Fatal("TUN must take precedence over an existing metric-zero default route")
	}
}

func TestEffectiveNetworkCapabilities(t *testing.T) {
	for _, revision := range []uint32{0x02000000, 0x03000000} {
		data := make([]byte, 24)
		binary.LittleEndian.PutUint32(data, revision|1)
		binary.LittleEndian.PutUint32(data[4:], 1<<12|1<<13)
		if !effectiveNetworkCapabilities(data) {
			t.Fatal("valid network capabilities refused")
		}
		binary.LittleEndian.PutUint32(data[4:], 1<<12)
		if effectiveNetworkCapabilities(data) {
			t.Fatal("missing raw capability accepted")
		}
		binary.LittleEndian.PutUint32(data[4:], 1<<12|1<<13)
		binary.LittleEndian.PutUint32(data, revision)
		if effectiveNetworkCapabilities(data) {
			t.Fatal("ineffective capabilities accepted")
		}
	}
	if effectiveNetworkCapabilities([]byte{1, 2, 3}) {
		t.Fatal("truncated capabilities accepted")
	}
	data := make([]byte, 24)
	binary.LittleEndian.PutUint32(data, 0x03000001)
	binary.LittleEndian.PutUint32(data[4:], 1<<12|1<<13)
	binary.LittleEndian.PutUint32(data[20:], 1000)
	if effectiveNetworkCapabilities(data) {
		t.Fatal("foreign namespace capabilities accepted")
	}
}
