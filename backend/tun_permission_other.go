//go:build !linux

package main

func canCreateTun(string) bool { return isElevated() }
