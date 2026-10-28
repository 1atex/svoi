package main

import (
	"flag"
	"log"
	"net"
	"net/http"
	"svoi/internal/speedtest"
	"time"
)

func main() {
	address := flag.String("listen", "127.0.0.1:8792", "Loopback listen address")
	flag.Parse()
	host, _, err := net.SplitHostPort(*address)
	if err != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
		log.Fatal("Use a loopback listen address")
	}
	server := &http.Server{Addr: *address, Handler: speedtest.NewHandler(8), ReadHeaderTimeout: 4 * time.Second, ReadTimeout: 12 * time.Second, WriteTimeout: 12 * time.Second, IdleTimeout: 10 * time.Second, MaxHeaderBytes: 8192}
	log.Print("SVOI speed measurement service: ", *address)
	log.Fatal(server.ListenAndServe())
}
