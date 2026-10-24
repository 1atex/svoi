package backend

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestNativeBackendCapability(t *testing.T) {
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })
	h := nativeHandler(next, "private-capability")
	for _, test := range []struct {
		path, key string
		code      int
	}{{"/api/health", "", 403}, {"/api/groups", "wrong", 403}, {"/api/health", "private-capability", 204}, {"/", "private-capability", 404}, {"/api/updates/install", "", 403}, {"/api/updates", "private-capability", 204}} {
		r := httptest.NewRequest("GET", test.path, nil)
		r.Header.Set("X-SVOI-Backend", test.key)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != test.code {
			t.Fatalf("%s got %d, want %d", test.path, w.Code, test.code)
		}
	}
	for _, address := range []string{"0.0.0.0:0", "localhost:0", "example.com:8787", "invalid"} {
		if validateNativeAddress(address) == nil {
			t.Fatalf("accepted %s", address)
		}
	}
	for _, address := range []string{"127.0.0.1:0", "[::1]:8788"} {
		if err := validateNativeAddress(address); err != nil {
			t.Fatal(err)
		}
	}
}

func TestNativeBackendExitsOnParentPipeEOF(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	input, parent := io.Pipe()
	defer parent.Close()
	output, writer := io.Pipe()
	defer output.Close()
	defer writer.Close()
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })}
	done := make(chan error, 1)
	go func() { done <- serveNativeBackend(server, listener, input, writer) }()
	var ready struct{ Address, Key string }
	if err := json.NewDecoder(output).Decode(&ready); err != nil {
		t.Fatal(err)
	}
	if ready.Key == "" || ready.Address == "" {
		t.Fatal("missing private bootstrap")
	}
	request, _ := http.NewRequest("GET", ready.Address+"/api/health", nil)
	request.Header.Set("X-SVOI-Backend", ready.Key)
	client := &http.Client{Timeout: time.Second}
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 204 {
		t.Fatal(response.StatusCode)
	}
	parent.Close()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(4 * time.Second):
		t.Fatal("orphaned backend")
	}
}
