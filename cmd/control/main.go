package main

import (
	"context"
	"github.com/euler-gaozl/agent-os/internal/servicehost"
	"github.com/euler-gaozl/agent-os/internal/servicehttp"
	"github.com/euler-gaozl/agent-os/services/console"
	"github.com/jackc/pgx/v5/pgxpool"
	"net/http"
)

func main() {
	servicehost.Main("control", "8090", func(ctx context.Context, p *pgxpool.Pool, c servicehttp.Config) (http.Handler, func(context.Context) error, error) {
		return (&console.Server{HTTP: c, Client: servicehost.Client(), SourcesURL: servicehost.Env("SOURCES_URL", "http://127.0.0.1:8101"), KnowledgeURL: servicehost.Env("KNOWLEDGE_URL", "http://127.0.0.1:8095"), StorageURL: servicehost.Env("STORAGE_URL", "http://127.0.0.1:8092"), WebDir: servicehost.Env("WEB_DIR", "web/dist")}).Handler(), nil, nil
	})
}
