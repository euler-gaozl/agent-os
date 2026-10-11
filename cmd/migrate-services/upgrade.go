package main

import (
	"context"
	"errors"
	"time"

	"github.com/euler-gaozl/agent-os/internal/platform"
	"github.com/euler-gaozl/agent-os/services/knowledge"
	"github.com/euler-gaozl/agent-os/services/sources"
	"github.com/euler-gaozl/agent-os/services/toolhub"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// This is a schema-only release job. Bootstrap/import is intentionally a
// different path: normal releases must not rewrite every service's config.
func upgradeService(parent context.Context, dsn, service string) error {
	schema, roles, tables := "public", []string{}, []string{}
	switch service {
	case "control", "futures":
		return nil // BFFs have no database.
	case "knowledge", "indexer":
		schema, roles = "knowledge", []string{"knowledge", "indexer"}
	case "toolhub", "sources":
		schema, roles = service, []string{service}
	case "registry":
		roles, tables = []string{service}, []string{"resources", "secrets"}
	case "runtime", "worker":
		roles, tables = []string{"runtime", "worker"}, []string{"runs", "events", "calls", "model_attempts", "harness_exchanges", "app_runs", "business_runs", "instances"}
	case "storage":
		roles, tables = []string{"storage", "runtime", "worker"}, []string{"documents", "artifacts", "artifact_refs"}
	case "sandbox":
		roles, tables = []string{service}, []string{"sandbox_jobs"}
	case "telemetry":
		roles, tables = []string{service}, []string{"telemetry_exports", "telemetry_inbox"}
	default:
		return errors.New("unknown service; no migration performed")
	}
	config, e := pgxpool.ParseConfig(dsn)
	if e != nil || dsn == "" {
		return errors.New("migration database configuration required")
	}
	config.MaxConns = 2
	config.ConnConfig.ConnectTimeout = 5 * time.Second
	config.ConnConfig.RuntimeParams["search_path"] = schema
	config.ConnConfig.RuntimeParams["lock_timeout"] = "3000"
	config.ConnConfig.RuntimeParams["statement_timeout"] = "120000"
	ctx, cancel := context.WithTimeout(parent, 3*time.Minute)
	defer cancel()
	db, e := pgxpool.NewWithConfig(ctx, config)
	if e != nil {
		return errors.New("cannot open migration database")
	}
	defer db.Close()
	// Initial provisioning creates schemas and scoped roles. Refuse an
	// accidental new database instead of silently building a partial platform.
	var exists bool
	if e = db.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname=$1)", schema).Scan(&exists); e != nil || !exists {
		return errors.New("selected schema is not provisioned")
	}
	switch schema {
	case "knowledge":
		e = knowledge.Migrate(ctx, db)
	case "toolhub":
		e = (&toolhub.Store{DB: db}).Migrate(ctx)
	case "sources":
		e = sources.Migrate(ctx, db)
	default:
		e = platform.MigrateService(ctx, db, service)
	}
	if e != nil {
		return e
	}
	for _, role := range roles {
		user := "agentos_" + role
		if e = db.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=$1)", user).Scan(&exists); e != nil {
			return e
		}
		if !exists {
			continue // Operator may provision another role on a dedicated DB.
		}
		ident := pgx.Identifier{user}.Sanitize()
		if schema != "public" {
			for _, q := range []string{
				"GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA " + pgx.Identifier{schema}.Sanitize() + " TO " + ident,
				"GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA " + pgx.Identifier{schema}.Sanitize() + " TO " + ident,
			} {
				if _, e = db.Exec(ctx, q); e != nil {
					return e
				}
			}
		} else {
			for _, table := range tables {
				if _, e = db.Exec(ctx, "GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE "+pgx.Identifier{schema, table}.Sanitize()+" TO "+ident); e != nil {
					return e
				}
			}
			if service == "runtime" || service == "worker" {
				if _, e = db.Exec(ctx, "GRANT USAGE,SELECT ON SEQUENCE public.events_seq_seq TO "+ident); e != nil {
					return e
				}
			}
		}
	}
	return nil
}
