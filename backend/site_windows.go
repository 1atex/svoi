//go:build windows

package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net"
	"syscall"
	"time"
)

func siteDirectNetwork(ctx context.Context) (*net.Dialer, string, error) {
	b, err := dnsPowerShell(ctx, `$up=@(Get-NetAdapter | Where-Object {$_.Status -eq 'Up' -and $_.HardwareInterface}); $r=Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' | Where-Object {$up.ifIndex -contains $_.InterfaceIndex} | Sort-Object RouteMetric,InterfaceMetric | Select-Object -First 1; if(!$r){throw 'No physical IPv4 default route'}; $a=$up | Where-Object {$_.ifIndex -eq $r.InterfaceIndex} | Select-Object -First 1; [pscustomobject]@{index=[int]$a.ifIndex;name=$a.Name;servers=@((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4).ServerAddresses)} | ConvertTo-Json -Compress`)
	if err != nil {
		return nil, "", fmt.Errorf("Не найден прямой маршрут через физический адаптер: %w", err)
	}
	var adapter dnsAdapter
	if err = json.Unmarshal(b, &adapter); err != nil || adapter.Index <= 0 || len(adapter.Servers) == 0 {
		return nil, "", fmt.Errorf("У физического адаптера нет IPv4 DNS")
	}
	if net.ParseIP(adapter.Servers[0]).To4() == nil {
		return nil, "", fmt.Errorf("DNS адаптера не является IPv4-адресом")
	}
	index := uint32(adapter.Index)
	var encoded [4]byte
	binary.BigEndian.PutUint32(encoded[:], index)
	networkIndex := int(binary.LittleEndian.Uint32(encoded[:]))
	control := func(_, _ string, conn syscall.RawConn) error {
		var bindErr error
		err := conn.Control(func(fd uintptr) {
			bindErr = syscall.SetsockoptInt(syscall.Handle(fd), syscall.IPPROTO_IP, 31, networkIndex)
		})
		if err != nil {
			return err
		}
		return bindErr
	}
	dnsDialer := &net.Dialer{Timeout: 3 * time.Second, Control: control}
	resolver := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
		if network == "tcp" {
			network = "tcp4"
		} else {
			network = "udp4"
		}
		return dnsDialer.DialContext(ctx, network, net.JoinHostPort(adapter.Servers[0], "53"))
	}}
	return &net.Dialer{Timeout: 4 * time.Second, Control: control, Resolver: resolver}, adapter.Name + " · DNS " + adapter.Servers[0], nil
}
