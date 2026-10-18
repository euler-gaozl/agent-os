package servicehost

import (
	"context"
	"os"
	"testing"

	"github.com/euler-gaozl/agent-os/internal/contracts"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestReadinessRequiresVersionSchemaNotJustDatabaseConnection(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("PostgreSQL required")
	}
	ctx := context.Background()
	admin, e := pgxpool.New(ctx, dsn)
	if e != nil {
		t.Fatal(e)
	}
	defer admin.Close()
	schema := "ready_test_" + contracts.ID()
	if _, e = admin.Exec(ctx, "CREATE SCHEMA "+pgx.Identifier{schema}.Sanitize()); e != nil {
		t.Fatal(e)
	}
	defer admin.Exec(ctx, "DROP SCHEMA "+pgx.Identifier{schema}.Sanitize()+" CASCADE")
	config, e := pgxpool.ParseConfig(dsn)
	if e != nil {
		t.Fatal(e)
	}
	config.ConnConfig.RuntimeParams["search_path"] = schema
	db, e := pgxpool.NewWithConfig(ctx, config)
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	if e = db.Ping(ctx); e != nil {
		t.Fatal(e)
	}
	ready := SchemaReadiness("registry", db)
	if ready(ctx) == nil {
		t.Fatal("empty database reported ready")
	}
	if _, e = db.Exec(ctx, "CREATE TABLE resources(kind text,revision integer,spec jsonb); CREATE TABLE secrets(sealed bytea)"); e != nil {
		t.Fatal(e)
	}
	if e = ready(ctx); e != nil {
		t.Fatal(e)
	}
	if _, e = db.Exec(ctx, "ALTER TABLE resources RENAME COLUMN revision TO old_revision"); e != nil {
		t.Fatal(e)
	}
	if ready(ctx) == nil {
		t.Fatal("incompatible schema reported ready")
	}
	if SchemaReadiness("unknown", db)(ctx) == nil {
		t.Fatal("unknown service accepted")
	}
	if SchemaReadiness("control", nil) != nil || SchemaReadiness("futures", nil) != nil {
		t.Fatal("gateway depends on a database")
	}
}
