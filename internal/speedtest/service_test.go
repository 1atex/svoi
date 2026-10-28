package speedtest

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestPayloadContractAndLimits(t *testing.T) {
	s := httptest.NewServer(NewHandler(2))
	defer s.Close()
	for _, tc := range []struct {
		method, path string
		data         []byte
		status       int
	}{{"GET", "ping", nil, 204}, {"GET", "download?bytes=8192", nil, 200}, {"GET", "download?bytes=999999999", nil, 400}, {"POST", "upload", bytes.Repeat([]byte{3}, 10000), 200}, {"POST", "upload", make([]byte, MaxUpload+1), 413}, {"GET", "upload", nil, 404}} {
		req, _ := http.NewRequest(tc.method, s.URL+Prefix+tc.path, bytes.NewReader(tc.data))
		r, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(r.Body)
		r.Body.Close()
		if r.StatusCode != tc.status || r.Header.Get("X-SVOI-Speed") != "1" {
			t.Fatal(tc.path, r.StatusCode)
		}
		if tc.path == "download?bytes=8192" && (len(body) != 8192 || r.ContentLength != 8192 || r.Header.Get("Content-Encoding") != "") {
			t.Fatal("invalid download", len(body), r.Header)
		}
		if tc.path == "upload" && tc.status == 200 {
			var ack struct{ Bytes int }
			if json.Unmarshal(body, &ack) != nil || ack.Bytes != len(tc.data) {
				t.Fatal("invalid acknowledgment", string(body))
			}
		}
	}
}
