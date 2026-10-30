package main

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

func coreEnvironment(id string) []string {
	if id != "mihomo" {
		return os.Environ()
	}
	env := []string{}
	for _, value := range os.Environ() {
		key, _, _ := strings.Cut(value, "=")
		if !strings.HasPrefix(strings.ToUpper(key), "CLASH_") {
			env = append(env, value)
		}
	}
	return env
}

func prepareEngineReadiness(cmd *exec.Cmd, id, directory string) (func() bool, func(), error) {
	cmd.Env = coreEnvironment(id)
	if id != "mihomo" {
		return func() bool { return true }, func() {}, nil
	}
	directory, err := filepath.Abs(directory)
	if err != nil {
		return nil, nil, err
	}
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		return nil, nil, err
	}
	nonce := hex.EncodeToString(random[:])
	name := ".svoi-ready-" + nonce
	path := filepath.Join(directory, name)
	// Mihomo invokes post-up after OnRunning; open proxy ports alone are earlier.
	// Only generated hex enters the shell command, never a provider value or path.
	command := "printf %s " + nonce + " > " + name
	if runtime.GOOS == "windows" {
		command = "echo " + nonce + " > " + name
	}
	cmd.Args = append(cmd.Args, "-post-up", command)
	cmd.Dir = directory
	return func() bool {
		data, err := os.ReadFile(path)
		return err == nil && strings.TrimSpace(string(data)) == nonce
	}, func() { _ = os.Remove(path) }, nil
}
