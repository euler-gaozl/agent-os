package main

import (
	"context"
	"github.com/euler-gaozl/agent-os/internal/servicehost"
	"github.com/euler-gaozl/agent-os/internal/servicehttp"
	"github.com/euler-gaozl/agent-os/services/knowledge"
	"github.com/jackc/pgx/v5/pgxpool"
	"net/http"
)

func main() {
	servicehost.Main("knowledge", "8095", func(ctx context.Context, p *pgxpool.Pool, c servicehttp.Config) (http.Handler, func(context.Context) error, error) {
		if e := servicehost.CheckSchema(ctx, p, "knowledge_files"); e != nil {
			return nil, nil, e
		}
		client := servicehost.Client()
		store := &knowledge.Store{DB: p, ResourceReader: client, SecretReader: client, RunReader: client}
		return (&knowledge.Server{Store: store, HTTP: c}).Handler(), nil, nil
	})
}
