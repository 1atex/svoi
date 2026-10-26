//go:build !windows

package main

import "context"

func systemDNSAdapters(context.Context) ([]dnsAdapter, error) {
	return nil, fail(400, "Настройки DNS доступны в Windows")
}
func setSystemDNS(context.Context, int, []string) error {
	return fail(400, "Настройки DNS доступны в Windows")
}
