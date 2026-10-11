package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"github.com/euler-gaozl/agent-os/internal/contracts"
	"github.com/euler-gaozl/agent-os/internal/platform"
	"github.com/euler-gaozl/agent-os/internal/servicehost"
	"github.com/euler-gaozl/agent-os/internal/servicehttp"
	"github.com/euler-gaozl/agent-os/services/knowledge"
	"github.com/euler-gaozl/agent-os/services/toolhub"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

func main() {
	output := flag.String("output", ".state/services", "private per-service configuration directory")
	if e := servicehost.Load(); e != nil {
		fail(e)
	}
	if e := run(*output); e != nil {
		fail(e)
	}
}
func fail(e error) { fmt.Fprintln(os.Stderr, e); os.Exit(1) }
func run(output string) error {
	ctx := context.Background()
	base := os.Getenv("DATABASE_URL")
	admin, e := platform.Open(ctx, base)
	if e != nil {
		return e
	}
	defer admin.DB.Close()
	if e = admin.Migrate(ctx); e != nil {
		return e
	}
	if e = os.MkdirAll(output, 0700); e != nil {
		return e
	}
	for _, name := range []string{"toolhub", "knowledge"} {
		if _, e = admin.DB.Exec(ctx, "CREATE SCHEMA IF NOT EXISTS "+pgx.Identifier{name}.Sanitize()); e != nil {
			return e
		}
	}
	scoped := func(name string) (*pgxpool.Pool, error) {
		u, e := url.Parse(base)
		if e != nil {
			return nil, e
		}
		q := u.Query()
		q.Set("search_path", name)
		u.RawQuery = q.Encode()
		return pgxpool.New(ctx, u.String())
	}
	hubPool, e := scoped("toolhub")
	if e != nil {
		return e
	}
	defer hubPool.Close()
	hub := &toolhub.Store{DB: hubPool, Policy: toolhub.Policy{AllowedHosts: strings.Split(os.Getenv("MCP_ALLOWED_HOSTS"), ",")}}
	if e = hub.Migrate(ctx); e != nil {
		return e
	}
	rows, e := admin.DB.Query(ctx, "SELECT kind,id,revision,spec FROM resources WHERE kind IN('skill','connector') ORDER BY kind,id,revision")
	if e != nil {
		return e
	}
	var resources []contracts.Resource
	for rows.Next() {
		var r contracts.Resource
		if e = rows.Scan(&r.Kind, &r.ID, &r.Revision, &r.Spec); e != nil {
			rows.Close()
			return e
		}
		resources = append(resources, r)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return e
	}
	for _, r := range resources {
		if e = hub.ImportLegacy(ctx, r); e != nil {
			return e
		}
	}
	kbPool, e := scoped("knowledge")
	if e != nil {
		return e
	}
	defer kbPool.Close()
	if e = knowledge.Migrate(ctx, kbPool); e != nil {
		return e
	}
	if e = knowledge.ImportLegacy(ctx, kbPool); e != nil {
		return e
	}
	execution := []string{"runs", "events", "calls", "model_attempts", "harness_exchanges", "documents", "artifacts", "artifact_refs", "app_runs", "business_runs", "instances"}
	grants := map[string][]string{"runtime": execution, "worker": execution, "registry": {"resources", "secrets"}, "storage": {"documents", "artifacts", "artifact_refs"}, "sandbox": {"runs", "sandbox_jobs"}, "telemetry": {"events", "telemetry_exports"}, "toolhub": nil, "knowledge": nil, "indexer": nil, "control": nil, "futures": nil}
	identities := map[string]string{}
	identityFile := filepath.Join(output, "identities.json")
	if raw, err := os.ReadFile(identityFile); err == nil {
		if e = json.Unmarshal(raw, &identities); e != nil {
			return e
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	peers := map[string]string{}
	for role := range grants {
		if len(identities[role]) < 32 {
			identities[role] = contracts.ID() + contracts.ID()
		}
		peers[role] = servicehttp.TokenHash(identities[role])
	}
	if e = writeConfig(identityFile, identities); e != nil {
		return e
	}
	for role, tables := range grants {
		cfg := map[string]string{}
		for _, key := range []string{"SERVICE_TOKEN", "ADMIN_TOKEN", "BUSINESS_TOKEN", "DEV_LOCAL", "REGISTRY_URL", "RUNTIME_URL", "TOOLHUB_URL", "KNOWLEDGE_URL", "STORAGE_URL", "SANDBOX_URL", "AGENTOS_NODE", "DSH_RUNNER", "WEB_DIR", "FUTURES_WEB_DIR", "MCP_ALLOWED_HOSTS", "SANDBOX_IMAGE", "LANGFUSE_URL"} {
			if value := os.Getenv(key); value != "" {
				cfg[key] = value
			}
		}
		cfg["DB_MAX_CONNS"] = "3"
		cfg["SERVICE_TOKEN"] = identities[role]
		cfg["SERVICE_PEERS"] = string(contracts.JSON(peers))
		cfg["GOMEMLIMIT"] = "96MiB"
		if role == "registry" {
			cfg["MASTER_KEY"] = os.Getenv("MASTER_KEY")
		}
		if role == "worker" {
			cfg["GOMEMLIMIT"] = "192MiB"
		}
		if role == "control" {
			delete(cfg, "BUSINESS_TOKEN")
		}
		if role == "futures" {
			delete(cfg, "ADMIN_TOKEN")
		}
		if role != "control" && role != "futures" {
			delete(cfg, "ADMIN_TOKEN")
			delete(cfg, "BUSINESS_TOKEN")
		}
		file := filepath.Join(output, role+".json")
		if role == "control" || role == "futures" {
			if e = writeConfig(file, cfg); e != nil {
				return e
			}
			continue
		}
		user := "agentos_" + role
		schema := "public"
		if role == "toolhub" {
			schema = "toolhub"
		}
		if role == "knowledge" || role == "indexer" {
			schema = "knowledge"
		}
		password := contracts.ID() + contracts.ID()
		old := map[string]string{}
		if raw, err := os.ReadFile(file); err == nil {
			if e = json.Unmarshal(raw, &old); e != nil {
				return e
			}
			u, e := url.Parse(old["DATABASE_URL"])
			if e != nil {
				return e
			}
			if u.User == nil || u.User.Username() != user {
				return errors.New("unexpected existing service database identity")
			}
			password, _ = u.User.Password()
		}
		var exists bool
		if e = admin.DB.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=$1)", user).Scan(&exists); e != nil {
			return e
		}
		if exists && old["DATABASE_URL"] == "" {
			return fmt.Errorf("role %s already exists without managed config; refusing to reset it", user)
		}
		u, e := url.Parse(base)
		if e != nil {
			return e
		}
		u.User = url.UserPassword(user, password)
		q := u.Query()
		q.Set("search_path", schema)
		u.RawQuery = q.Encode()
		cfg["DATABASE_URL"] = u.String()
		if e = writeConfig(file, cfg); e != nil {
			return e
		}
		ident := pgx.Identifier{user}.Sanitize()
		if !exists {
			if _, e = admin.DB.Exec(ctx, "CREATE ROLE "+ident+" LOGIN PASSWORD '"+strings.ReplaceAll(password, "'", "''")+"'"); e != nil {
				return errors.New("cannot create service database role")
			}
		}
		if _, e = admin.DB.Exec(ctx, "GRANT USAGE ON SCHEMA "+pgx.Identifier{schema}.Sanitize()+" TO "+ident); e != nil {
			return e
		}
		if schema != "public" {
			if _, e = admin.DB.Exec(ctx, "GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA "+pgx.Identifier{schema}.Sanitize()+" TO "+ident); e != nil {
				return e
			}
			if _, e = admin.DB.Exec(ctx, "GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA "+pgx.Identifier{schema}.Sanitize()+" TO "+ident); e != nil {
				return e
			}
		} else {
			for _, table := range tables {
				if _, e = admin.DB.Exec(ctx, "GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE "+pgx.Identifier{"public", table}.Sanitize()+" TO "+ident); e != nil {
					return e
				}
			}
			if role == "runtime" || role == "worker" {
				if _, e = admin.DB.Exec(ctx, "GRANT USAGE,SELECT ON SEQUENCE public.events_seq_seq TO "+ident); e != nil {
					return e
				}
			}
		}
	}
	fmt.Println("Service schemas migrated; private per-service configurations written. Original data retained.")
	return nil
}
func writeConfig(path string, cfg map[string]string) error {
	b, e := json.MarshalIndent(cfg, "", "  ")
	if e != nil {
		return e
	}
	temp := path + ".new"
	if e = os.WriteFile(temp, b, 0600); e != nil {
		return e
	}
	return os.Rename(temp, path)
}
