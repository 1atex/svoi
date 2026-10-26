package mobile

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestPublicIPValidation(t *testing.T) {
	for _, body := range []string{"203.0.113.5", "127.0.0.1", "192.168.0.1", "<html>error", strings.Repeat("a", 65)} {
		t.Run(body[:min(len(body), 15)], func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(body)) }))
			defer srv.Close()
			ip, err := fetchPublicIP(context.Background(), srv.URL)
			if (err == nil) != (body == "203.0.113.5") || (err == nil && ip != body) {
				t.Fatal(ip, err)
			}
		})
	}
}

func TestPublicIPDoesNotFollowRedirectAndCancels(t *testing.T) {
	closed := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/redirect" {
			http.Redirect(w, r, "/ok", 302)
			return
		}
		<-r.Context().Done()
		close(closed)
	}))
	defer srv.Close()
	if _, err := fetchPublicIP(context.Background(), srv.URL+"/redirect"); err == nil {
		t.Fatal("redirect accepted")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if _, err := fetchPublicIP(ctx, srv.URL); err == nil {
		t.Fatal("timeout accepted")
	}
	select {
	case <-closed:
	case <-time.After(time.Second):
		t.Fatal("connection remains open")
	}
}

func TestPublicIPCancelledOnDisconnectAndSuperseded(t *testing.T) {
	p := NewPublicIPRequest()
	q := NewPublicIPRequest()
	if p.ctx.Err() == nil {
		t.Fatal("older request still active")
	}
	Stop()
	if q.ctx.Err() == nil {
		t.Fatal("disconnect did not cancel IP")
	}
}
