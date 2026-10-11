package main

import (
	"context"
	"github.com/euler-gaozl/agent-os/internal/servicehost"
	"github.com/euler-gaozl/agent-os/internal/servicehttp"
	"github.com/euler-gaozl/agent-os/services/sources"
	"github.com/jackc/pgx/v5/pgxpool"
	"net/http"
	"strings"
)

func main() {
	servicehost.Main("sources", "8101", func(ctx context.Context, p *pgxpool.Pool, c servicehttp.Config) (http.Handler, func(context.Context) error, error) {
		if e := servicehost.CheckSchema(ctx, p, "source_captures"); e != nil {
			return nil, nil, e
		}
		hosts := strings.Split(servicehost.Env("SOURCE_ALLOWED_HOSTS", strings.Join(sources.DefaultHosts, ",")), ",")
		return (&sources.Store{DB: p, AllowedHosts: hosts}).Handler(c), nil, nil
	})
}
