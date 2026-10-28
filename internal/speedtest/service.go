package speedtest

import (
	"crypto/rand"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
)

const Prefix = "/speed/v1/"
const MaxDownload = 8 << 20
const MaxUpload = 2 << 20

func NewHandler(parallel int) http.Handler {
	slots := make(chan struct{}, parallel)
	payload := make([]byte, 64<<10)
	if _, err := rand.Read(payload); err != nil {
		panic(err)
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store, no-transform")
		w.Header().Set("X-SVOI-Speed", "1")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		select {
		case slots <- struct{}{}:
			defer func() { <-slots }()
		default:
			http.Error(w, "Test node busy", 503)
			return
		}
		switch {
		case r.URL.Path == Prefix+"ping" && r.Method == http.MethodGet:
			w.WriteHeader(204)
		case r.URL.Path == Prefix+"download" && r.Method == http.MethodGet:
			n, err := strconv.ParseInt(r.URL.Query().Get("bytes"), 10, 64)
			if err != nil || n < 1 || n > MaxDownload {
				http.Error(w, "Invalid size", 400)
				return
			}
			w.Header().Set("Content-Type", "application/octet-stream")
			w.Header().Set("Content-Length", strconv.FormatInt(n, 10))
			for n > 0 {
				count := min(n, int64(len(payload)))
				if _, err = w.Write(payload[:count]); err != nil {
					return
				}
				n -= count
			}
		case r.URL.Path == Prefix+"upload" && r.Method == http.MethodPost:
			if r.ContentLength < 0 || r.ContentLength > MaxUpload {
				http.Error(w, "Invalid size", 413)
				return
			}
			n, err := io.Copy(io.Discard, http.MaxBytesReader(w, r.Body, MaxUpload))
			if err != nil || n != r.ContentLength {
				http.Error(w, "Incomplete upload", 400)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(struct {
				Bytes int64 `json:"bytes"`
			}{n})
		default:
			http.NotFound(w, r)
		}
	})
}
