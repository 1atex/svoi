//go:build windows

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os/exec"
	"strconv"
	"strings"

	"golang.org/x/sys/windows/registry"
)

func dnsPowerShell(ctx context.Context, script string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", "$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[System.Text.UTF8Encoding]::new(); "+script)
	hideCommand(cmd)
	b, err := cmd.CombinedOutput()
	if err != nil {
		if ctx.Err() != nil {
			return nil, fmt.Errorf("Проверка настроек DNS отменена или заняла слишком много времени: %w", ctx.Err())
		}
		if len(b) == 0 {
			return nil, fmt.Errorf("DNS Windows: %w", err)
		}
		return nil, fmt.Errorf("DNS Windows: %s", strings.TrimSpace(string(b)))
	}
	return b, nil
}
func systemDNSAdapters(ctx context.Context) ([]dnsAdapter, error) {
	b, err := dnsPowerShell(ctx, `$items=@(Get-NetAdapter | Where-Object {$_.Status -eq 'Up' -and $_.HardwareInterface} | ForEach-Object {
 $a=$_; $servers=@((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4).ServerAddresses)
 [pscustomobject]@{index=[int]$a.ifIndex;id=$a.InterfaceGuid.ToString();name=$a.Name;servers=$servers}
}); ConvertTo-Json -InputObject $items -Compress -Depth 4`)
	if err != nil {
		return nil, err
	}
	adapters := []dnsAdapter{}
	if err = json.Unmarshal(b, &adapters); err != nil {
		return nil, err
	}
	for i := range adapters {
		id := "{" + strings.Trim(adapters[i].ID, "{}") + "}"
		key, e := registry.OpenKey(registry.LOCAL_MACHINE, `SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\`+id, registry.QUERY_VALUE)
		if e != nil {
			return nil, fmt.Errorf("Не удалось прочитать настройки адаптера %s: %w", adapters[i].Name, e)
		}
		value, _, e := key.GetStringValue("NameServer")
		key.Close()
		if e != nil && e != registry.ErrNotExist {
			return nil, e
		}
		adapters[i].Static = dnsStaticAddresses(value)
	}
	return adapters, nil
}
func setSystemDNS(ctx context.Context, index int, addresses []string) error {
	if index <= 0 {
		return fmt.Errorf("Некорректный индекс адаптера")
	}
	args := "-ResetServerAddresses"
	if len(addresses) > 0 {
		quoted := []string{}
		for _, address := range addresses {
			if ip := net.ParseIP(address); ip == nil || ip.To4() == nil {
				return fmt.Errorf("Некорректный IPv4 DNS")
			}
			quoted = append(quoted, "'"+address+"'")
		}
		args = "-ServerAddresses @(" + strings.Join(quoted, ",") + ")"
	}
	_, err := dnsPowerShell(ctx, "$target=@(Get-DnsClientServerAddress -InterfaceIndex "+strconv.Itoa(index)+" -AddressFamily IPv4); if($target.Count -ne 1){throw 'Network adapter is unavailable'}; $target[0] | Set-DnsClientServerAddress "+args)
	return err
}
