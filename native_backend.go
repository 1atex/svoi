package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

func validateNativeAddress(address string) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
		return fmt.Errorf("native backend must listen on a loopback IP")
	}
	return nil
}

// The launch capability is sent only over the parent's stdout pipe. It is not
// stored, placed in command-line arguments or exposed to ordinary web pages.
func nativeHandler(next http.Handler, capability string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if subtle.ConstantTimeCompare([]byte(r.Header.Get("X-SVOI-Backend")), []byte(capability)) != 1 {
			http.Error(w, "private desktop backend", http.StatusForbidden)
			return
		}
		if !strings.HasPrefix(r.URL.Path, "/api/") {
			http.NotFound(w, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func serveNativeBackend(server *http.Server, listener net.Listener, input io.Reader, output io.Writer) error {
	capability := secret()
	server.Handler = nativeHandler(server.Handler, capability)
	go func() {
		_, _ = io.Copy(io.Discard, input)
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if server.Shutdown(ctx) != nil {
			_ = server.Close()
		}
	}()
	if err := json.NewEncoder(output).Encode(map[string]any{"address": "http://" + listener.Addr().String(), "key": capability, "version": appVersion, "pid": os.Getpid()}); err != nil {
		return err
	}
	if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
