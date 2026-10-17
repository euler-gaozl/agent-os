package main

import (
	"context"
	"github.com/euler-gaozl/agent-os/internal/recordstore"
	"github.com/euler-gaozl/agent-os/internal/servicehost"
	"github.com/euler-gaozl/agent-os/internal/servicehttp"
	"github.com/euler-gaozl/agent-os/services/storage"
	"github.com/jackc/pgx/v5/pgxpool"
	"net/http"
)

func main() {
	servicehost.Main("storage", "8092", func(ctx context.Context, p *pgxpool.Pool, c servicehttp.Config) (http.Handler, func(context.Context) error, error) {
		s := &storage.Server{Store: &recordstore.Store{DB: p}, HTTP: c}
		return s.Handler(), nil, nil
	})
}
