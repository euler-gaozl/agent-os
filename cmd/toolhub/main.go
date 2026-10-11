package main

import (
	"context"
	"github.com/euler-gaozl/agent-os/internal/servicehost"
	"github.com/euler-gaozl/agent-os/internal/servicehttp"
	"github.com/euler-gaozl/agent-os/services/toolhub"
	"github.com/jackc/pgx/v5/pgxpool"
	"net/http"
	"os"
	"strings"
)

func main() {
	servicehost.Main("toolhub", "8091", func(ctx context.Context, p *pgxpool.Pool, c servicehttp.Config) (http.Handler, func(context.Context) error, error) {
		if e := servicehost.CheckSchema(ctx, p, "assets"); e != nil {
			return nil, nil, e
		}
		client := servicehost.Client()
		store := &toolhub.Store{DB: p, Policy: toolhub.Policy{AllowedHosts: strings.Split(os.Getenv("MCP_ALLOWED_HOSTS"), ",")}, Secrets: client}
		s := &toolhub.Server{Store: store, HTTP: c, Execution: client}
		return s.Handler(), func(ctx context.Context) error {
			return store.Monitor(ctx, servicehost.Env("INSTANCE_ID", "toolhub-monitor"))
		}, nil
	})
}
