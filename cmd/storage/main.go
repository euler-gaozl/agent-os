package main

import (
	"context"
	"github.com/euler-gaozl/agent-os/internal/platform"
	"github.com/euler-gaozl/agent-os/internal/servicehost"
	"github.com/euler-gaozl/agent-os/internal/servicehttp"
	"github.com/jackc/pgx/v5/pgxpool"
	"net/http"
)

func main() {
	servicehost.Main("storage", "8092", func(ctx context.Context, p *pgxpool.Pool, c servicehttp.Config) (http.Handler, func(context.Context) error, error) {
		client := servicehost.Client()
		store := &platform.Store{DB: p, Remote: &client, CatalogURL: client.CatalogURL}
		s := &platform.Server{Store: store, Role: "storage", Token: c.Token, RegistryURL: servicehost.Env("REGISTRY_URL", "http://127.0.0.1:8096"), RuntimeURL: servicehost.Env("RUNTIME_URL", "http://127.0.0.1:8094"), KnowledgeURL: servicehost.Env("KNOWLEDGE_URL", "http://127.0.0.1:8095"), SandboxURL: servicehost.Env("SANDBOX_URL", "http://127.0.0.1:8093"), StorageURL: servicehost.Env("STORAGE_URL", "http://127.0.0.1:8092")}
		return s.StorageHandler(c), nil, nil
	})
}
