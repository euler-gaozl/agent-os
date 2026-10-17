// Controlled HTTP-only Registry/Sources peer for real Knowledge binary tests.
// No network fetching, model calls, private data or production configuration.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"net/http"
	"os"
	"time"
)

func hash(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func main() {
	path := flag.String("config", "", "isolated fixture configuration")
	flag.Parse()
	body, err := os.ReadFile(*path)
	if err != nil {
		panic(err)
	}
	var c map[string]string
	if err = json.Unmarshal(body, &c); err != nil {
		panic(err)
	}
	raw := []byte("<p>隔离测试资料🙂库存120吨</p>")
	text := "隔离测试资料🙂库存120吨"
	id := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	bundle := map[string]any{"format": 1, "capture_id": id, "requested_url": "https://source.invalid/evidence", "final_url": "https://source.invalid/evidence", "media_type": "text/html; charset=utf-8", "fetched_at": "2026-01-01T00:00:00.123456Z", "title": "隔离发布测试", "extraction_version": "agentos-text-html-v1", "raw_sha256": hash(raw), "text_sha256": hash([]byte(text)), "raw_bytes": len(raw), "text_bytes": len(text), "raw": raw, "text": text}
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/healthz" {
			_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
			return
		}
		if r.Header.Get("Authorization") != "Bearer "+c["SERVICE_TOKEN"] && r.Header.Get("Authorization") != "Bearer "+c["KNOWLEDGE_TOKEN"] {
			w.WriteHeader(401)
			return
		}
		switch r.URL.Path {
		case "/readyz":
			_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
		case "/capture-capabilities":
			_ = json.NewEncoder(w).Encode(map[string]any{"protocol": "source-capture-v1", "durable_capture_ids": true})
		case "/captures/" + id + "/bundle":
			_ = json.NewEncoder(w).Encode(bundle)
		case "/v1/resources/knowledge/capture-release/1":
			_ = json.NewEncoder(w).Encode(map[string]any{"spec": map[string]any{"name": "Isolated capture release fixture", "engine": "local", "chunk_size": 200}})
		default:
			w.WriteHeader(404)
		}
	})
	srv := &http.Server{Addr: c["LISTEN"], Handler: h, ReadHeaderTimeout: 2 * time.Second, WriteTimeout: 5 * time.Second, IdleTimeout: 5 * time.Second}
	if err = srv.ListenAndServe(); err != nil {
		panic(err)
	}
}
