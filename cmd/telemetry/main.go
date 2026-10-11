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
	servicehost.Main("telemetry", "0", func(ctx context.Context, p *pgxpool.Pool, c servicehttp.Config) (http.Handler, func(context.Context) error, error) {
		client := servicehost.Client()
		store := &platform.Store{DB: p, Remote: &client, CatalogURL: client.CatalogURL}
		return servicehttp.New(c, p.Ping, func(*http.ServeMux) {}), func(ctx context.Context) error {
			return store.ExportTelemetry(ctx, servicehost.Env("LANGFUSE_URL", ""))
		}, nil
	})
}
