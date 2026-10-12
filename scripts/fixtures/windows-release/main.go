//go:build windows

// Synthetic authenticated health server for release transaction fault tests.
// It has no database, model transport or platform business effects.
package main

import (
	"encoding/json"
	"flag"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func main() {
	path := flag.String("config", "", "synthetic configuration")
	flag.Parse()
	raw, err := os.ReadFile(*path)
	if err != nil {
		panic("fixture config unavailable")
	}
	var config map[string]string
	if json.Unmarshal(raw, &config) != nil {
		panic("fixture config invalid")
	}
	binary, _ := os.Executable()
	mux := http.NewServeMux()
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+config["SERVICE_TOKEN"] {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if strings.Contains(filepath.Base(binary), "unready") {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic("fixture listen failed")
	}
	server := &http.Server{Handler: mux, ReadHeaderTimeout: time.Second}
	if server.Serve(listener) != nil {
		panic("fixture server exited")
	}
}
