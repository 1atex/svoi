//go:build !windows

package main

import (
	"context"
	"net"
	"time"
)

func siteDirectNetwork(context.Context) (*net.Dialer, string, error) {
	return &net.Dialer{Timeout: 4 * time.Second}, "Текущая сеть ОС", nil
}
