package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/euler-gaozl/agent-os/internal/platform"
)

func env(key, fallback string) string {
	if s := os.Getenv(key); s != "" {
		return s
	}
	return fallback
}
func run() error {
	role := flag.String("role", "control", "control, registry, runtime, worker, toolhub, storage, knowledge, indexer, sandbox, futures, telemetry, migrate, seed")
	config := flag.String("config", "", "optional local JSON environment file; never committed")
	flag.Parse()
	if *config != "" {
		b, e := os.ReadFile(*config)
		if e != nil {
			return e
		}
		var values map[string]string
		if e = json.Unmarshal(b, &values); e != nil {
			return e
		}
		for k, v := range values {
			if os.Getenv(k) == "" {
				if e = os.Setenv(k, v); e != nil {
					return e
				}
			}
		}
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	store, e := platform.Open(ctx, os.Getenv("DATABASE_URL"))
	if e != nil {
		return e
	}
	defer store.DB.Close()
	if *role == "migrate" {
		return store.Migrate(ctx)
	}
	if *role == "seed" {
		return seed(ctx, store)
	}
	token := os.Getenv("SERVICE_TOKEN")
	if len(token) < 32 || strings.Contains(token, "replace-with-") {
		return errors.New("SERVICE_TOKEN must contain at least 32 characters")
	}
	if admin := env("ADMIN_TOKEN", token); len(admin) < 32 || strings.Contains(admin, "replace-with-") {
		return errors.New("ADMIN_TOKEN must contain at least 32 generated characters")
	}
	id := env("INSTANCE_ID", *role+"-"+platform.ID()[:8])
	go platform.RegisterInstance(ctx, store, id, *role)
	if *role == "telemetry" {
		return store.ExportTelemetry(ctx, os.Getenv("LANGFUSE_URL"))
	}
	if *role == "worker" {
		worker := platform.Worker{Store: store, ID: id, Token: token, ToolHubURL: env("TOOLHUB_URL", "http://127.0.0.1:8091")}
		return worker.Run(ctx)
	}
	if *role == "indexer" {
		return store.RunIndexer(ctx)
	}
	ports := map[string]string{"control": "8090", "toolhub": "8091", "storage": "8092", "sandbox": "8093", "runtime": "8094", "knowledge": "8095", "registry": "8096", "futures": "8098"}
	port, ok := ports[*role]
	if !ok {
		return errors.New("unknown role")
	}
	local := os.Getenv("DEV_LOCAL") == "1"
	listen := env("LISTEN", "127.0.0.1:"+port)
	if local && (*role == "control" || *role == "futures") && listen != "127.0.0.1:"+port {
		return errors.New("DEV_LOCAL control requires loopback binding")
	}
	server := platform.Server{Store: store, Role: *role, Token: token, AdminToken: env("ADMIN_TOKEN", token), DevLocal: local, StorageURL: env("STORAGE_URL", "http://127.0.0.1:8092"), SandboxURL: env("SANDBOX_URL", "http://127.0.0.1:8093"), WebDir: env("WEB_DIR", "web/dist")}
	server.RuntimeURL = env("RUNTIME_URL", "http://127.0.0.1:8094")
	server.RegistryURL = env("REGISTRY_URL", "http://127.0.0.1:8096")
	server.KnowledgeURL = env("KNOWLEDGE_URL", "http://127.0.0.1:8095")
	if *role == "futures" {
		server.WebDir = env("FUTURES_WEB_DIR", "web/dist-futures")
		server.AdminToken = env("BUSINESS_TOKEN", env("ADMIN_TOKEN", token))
	}
	httpServer := &http.Server{Addr: listen, Handler: server.Handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 100 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16384}
	go func() {
		<-ctx.Done()
		shutdown, c := context.WithTimeout(context.Background(), 10*time.Second)
		defer c()
		_ = httpServer.Shutdown(shutdown)
	}()
	slog.Info("service started", "role", *role, "instance", id, "listen", listen)
	return httpServer.ListenAndServe()
}
func seed(ctx context.Context, s *platform.Store) error {
	paths, e := filepath.Glob("packs/*/*.json")
	if e != nil {
		return e
	}
	for _, path := range paths {
		b, e := os.ReadFile(path)
		if e != nil {
			return e
		}
		var r platform.Resource
		if e = json.Unmarshal(b, &r); e != nil {
			return e
		}
		var existing int
		if e = s.DB.QueryRow(ctx, "SELECT count(*) FROM resources WHERE kind=$1 AND id=$2", r.Kind, r.ID).Scan(&existing); e != nil {
			return e
		}
		if existing > 0 {
			continue
		}
		if _, e = s.PutResource(ctx, r.Kind, r.ID, r.Spec); e != nil {
			return e
		}
		slog.Info("seeded resource", "kind", r.Kind, "id", r.ID)
	}
	return nil
}
func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	if e := run(); e != nil && !errors.Is(e, context.Canceled) && !errors.Is(e, http.ErrServerClosed) {
		slog.Error("service stopped", "error", e)
		os.Exit(1)
	}
}
