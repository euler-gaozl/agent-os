package main

import (
	"context"
	"errors"
	"net/url"
	"os"
	"testing"

	"github.com/euler-gaozl/agent-os/internal/contracts"
	"github.com/euler-gaozl/agent-os/internal/platform"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestRetirementRevokesLegacyPrivilegesWithoutChangingNotes(t *testing.T) {
	base := os.Getenv("TEST_DATABASE_URL")
	if base == "" {
		t.Skip("TEST_DATABASE_URL absent")
	}
	ctx := context.Background()
	admin, e := pgxpool.New(ctx, base)
	if e != nil {
		t.Fatal(e)
	}
	defer admin.Close()
	name := "agentos_retire_" + contracts.ID()
	if _, e = admin.Exec(ctx, "CREATE DATABASE "+pgx.Identifier{name}.Sanitize()); e != nil {
		t.Fatal(e)
	}
	defer func() {
		if _, e := admin.Exec(ctx, "DROP DATABASE "+pgx.Identifier{name}.Sanitize()+" WITH (FORCE)"); e != nil {
			t.Error(e)
		}
	}()
	u, e := url.Parse(base)
	if e != nil {
		t.Fatal(e)
	}
	u.Path = "/" + name
	q := u.Query()
	q.Set("search_path", "public")
	u.RawQuery = q.Encode()
	db, e := pgxpool.New(ctx, u.String())
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	var roleExists bool
	if e = db.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='agentos_storage')").Scan(&roleExists); e != nil {
		t.Fatal(e)
	}
	if !roleExists {
		if _, e = db.Exec(ctx, "CREATE ROLE agentos_storage"); e != nil {
			t.Fatal(e)
		}
		defer func() {
			if _, e := db.Exec(ctx, "DROP OWNED BY agentos_storage; DROP ROLE agentos_storage"); e != nil {
				t.Error(e)
			}
		}()
	}
	if e = platform.MigrateService(ctx, db, "runtime"); e != nil {
		t.Fatal(e)
	}
	if _, e = db.Exec(ctx, `INSERT INTO documents(id,kind,title,content,source,metadata,scope) VALUES('retained','memory','fixture','keep me','test://retirement','{}','agent-a');
GRANT SELECT,INSERT,UPDATE,DELETE ON documents TO agentos_storage`); e != nil {
		t.Fatal(e)
	}
	if e = upgradeService(ctx, u.String(), "storage"); e != nil {
		t.Fatal(e)
	}
	var oldGrant bool
	if e = db.QueryRow(ctx, "SELECT has_table_privilege('agentos_storage','documents','INSERT')").Scan(&oldGrant); e != nil || !oldGrant {
		t.Fatal("expand migration prematurely revoked old consumer", e)
	}
	for range 2 {
		if e = retireStorageNoteAccess(ctx, u.String()); e != nil {
			t.Fatal(e)
		}
	}
	tx, e := db.Begin(ctx)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = tx.Exec(ctx, "SET LOCAL ROLE agentos_storage"); e != nil {
		t.Fatal(e)
	}
	_, e = tx.Exec(ctx, "SELECT content FROM public.documents")
	var denied *pgconn.PgError
	if !errors.As(e, &denied) || denied.Code != "42501" {
		t.Fatal("old Storage identity still reads notes", e)
	}
	_ = tx.Rollback(ctx)
	var content string
	if e = db.QueryRow(ctx, "SELECT content FROM documents WHERE id='retained'").Scan(&content); e != nil || content != "keep me" {
		t.Fatal("retirement changed data", e)
	}
}
