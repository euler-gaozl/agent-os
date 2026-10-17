//go:build windows

// Synthetic authenticated health server for release transaction fault tests.
// It has no database, model transport or platform business effects.
package main

import (
	"crypto/sha256"
	"encoding/hex"
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
		if (strings.Contains(config["MCP_ALLOWED_HOSTS"], ":8098") || strings.Contains(config["SOURCE_ALLOWED_HOSTS"], "example.org") || strings.Contains(config["APP_RECEIPT_EXPORTS"], "check-8098")) && config["unready_mcp_marker"] != "" {
			if _, err := os.Stat(config["unready_mcp_marker"]); err == nil {
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
		}
		if (config["DEFAULT_RUN_ENGINE"] == "dsh-source-639ed015-state-v1" || config["DEFAULT_RUN_ENGINE"] == "dsh-source-639ed015-resident-v2" || config["DEFAULT_RUN_ENGINE"] == "dsh-source-639ed015-budget-v3" || config["DEFAULT_RUN_ENGINE"] == "dsh-source-639ed015-native-v4" || config["DEFAULT_RUN_ENGINE"] == "dsh-source-639ed015-final-v5") && config["unready_source_marker"] != "" {
			if _, err := os.Stat(config["unready_source_marker"]); err == nil {
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
		}
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/fixture/engine", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+config["SERVICE_TOKEN"] {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"engine": config["DEFAULT_RUN_ENGINE"]})
	})
	mux.HandleFunc("/fixture/mcp-hosts", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+config["SERVICE_TOKEN"] {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"hosts": config["MCP_ALLOWED_HOSTS"]})
	})
	mux.HandleFunc("/fixture/source-hosts", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+config["SERVICE_TOKEN"] {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"hosts": config["SOURCE_ALLOWED_HOSTS"]})
	})
	mux.HandleFunc("/fixture/receipt-exports", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+config["SERVICE_TOKEN"] {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"hosts": config["APP_RECEIPT_EXPORTS"]})
	})
	mux.HandleFunc("/v1/receipt-projections", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+config["SERVICE_TOKEN"] {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		mode, _ := os.ReadFile(config["receipt_protocol_marker"])
		if string(mode) == "unsupported" {
			http.NotFound(w, r)
			return
		}
		sum := sha256.Sum256([]byte(config["APP_RECEIPT_EXPORTS"]))
		digest := hex.EncodeToString(sum[:])
		if string(mode) == "digest" && strings.Contains(config["APP_RECEIPT_EXPORTS"], "check-8098") {
			digest = strings.Repeat("0", 64)
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"protocol": "app-receipt-projection-v1", "configuration_sha256": digest})
	})
	address := config["LISTEN"]
	if address == "" {
		address = "127.0.0.1:0"
	}
	listener, err := net.Listen("tcp", address)
	if err != nil {
		panic("fixture listen failed")
	}
	server := &http.Server{Handler: mux, ReadHeaderTimeout: time.Second}
	if server.Serve(listener) != nil {
		panic("fixture server exited")
	}
}
