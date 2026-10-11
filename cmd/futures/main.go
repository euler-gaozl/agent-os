package main

import (
	"context"
	"github.com/euler-gaozl/agent-os/internal/servicehost"
	"github.com/euler-gaozl/agent-os/internal/servicehttp"
	"github.com/euler-gaozl/agent-os/services/futures"
	"github.com/jackc/pgx/v5/pgxpool"
	"net/http"
)

func main() {
	servicehost.Main("futures", "8098", func(ctx context.Context, p *pgxpool.Pool, c servicehttp.Config) (http.Handler, func(context.Context) error, error) {
		return (&futures.Server{HTTP: c, Client: servicehost.Client(), KnowledgeURL: servicehost.Env("KNOWLEDGE_URL", "http://127.0.0.1:8095"), WebDir: servicehost.Env("FUTURES_WEB_DIR", "web/dist-futures")}).Handler(), nil, nil
	})
}
