//go:build !linux && !darwin

package main

func canCreateTun(string) bool { return isElevated() }
