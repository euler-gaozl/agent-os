package platform

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/euler-gaozl/agent-os/internal/serviceclient"
	"github.com/euler-gaozl/agent-os/internal/servicehttp"
	"github.com/jackc/pgx/v5"
)

func separateSandboxStore(t *testing.T, execution *Store) (*Store, string, string) {
	t.Helper()
	s, dsn := testStore(t)
	ctx := context.Background()
	rows, e := s.DB.Query(ctx, "SELECT tablename FROM pg_tables WHERE schemaname=current_schema() AND tablename<>'sandbox_jobs'")
	if e != nil {
		t.Fatal(e)
	}
	var tables []string
	for rows.Next() {
		var name string
		if e = rows.Scan(&name); e != nil {
			t.Fatal(e)
		}
		tables = append(tables, name)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		t.Fatal(e)
	}
	for _, name := range tables {
		if _, e = s.DB.Exec(ctx, "DROP TABLE IF EXISTS "+pgx.Identifier{name}.Sanitize()+" CASCADE"); e != nil {
			t.Fatal(e)
		}
	}
	token := strings.Repeat("sandbox-fixture-", 3)
	cfg := servicehttp.Config{Role: "runtime", Token: testToken, Peers: map[string]string{"runtime": servicehttp.TokenHash(testToken), "sandbox": servicehttp.TokenHash(token)}}
	server := httptest.NewServer((&Server{Store: execution}).RuntimeHandler(cfg))
	t.Cleanup(server.Close)
	s.Remote = &serviceclient.Client{RuntimeURL: server.URL, Token: token}
	return s, dsn, server.URL
}

func sandboxIntent(t *testing.T, s *Store, inv Invocation) {
	t.Helper()
	tx, e := s.DB.Begin(context.Background())
	if e != nil {
		t.Fatal(e)
	}
	defer tx.Rollback(context.Background())
	if e = insertCall(context.Background(), tx, inv, "inflight", nil); e != nil {
		t.Fatal(e)
	}
	if e = tx.Commit(context.Background()); e != nil {
		t.Fatal(e)
	}
}

func TestSandboxAuthorizationWithSeparateJobDatabase(t *testing.T) {
	execution, _ := testStore(t)
	snap := basicSnapshot("https://fixture.invalid")
	snap.Agent.Tools = []string{"sandbox_exec"}
	submit(t, execution, snap)
	run := claim(t, execution, "sandbox-owner")
	s, _, _ := separateSandboxStore(t, execution)
	server := &Server{Store: s}
	inv := invocation(run)
	inv.Name, inv.Arguments = "sandbox_exec", JSON(map[string]string{"code": "console.log('fixture')"})
	ctx := context.Background()
	if e := server.validateSandboxInvocation(ctx, inv); e == nil {
		t.Fatal("accepted call without durable intent")
	}
	sandboxIntent(t, execution, inv)
	if e := server.validateSandboxInvocation(ctx, inv); e != nil {
		t.Fatal(e)
	}
	changed := inv
	changed.Arguments = JSON(map[string]string{"code": "console.log('different')"})
	if e := server.validateSandboxInvocation(ctx, changed); e == nil {
		t.Fatal("different arguments accepted for persisted intent")
	}
	changed = inv
	changed.Fence++
	if e := server.validateSandboxInvocation(ctx, changed); e == nil {
		t.Fatal("wrong fence accepted")
	}
	changed = inv
	changed.RuleRevision++
	if e := server.validateSandboxInvocation(ctx, changed); e == nil {
		t.Fatal("wrong constraints accepted")
	}
	if e := execution.Cancel(ctx, run.ID); e != nil {
		t.Fatal(e)
	}
	if e := server.validateSandboxInvocation(ctx, inv); e == nil {
		t.Fatal("cancelled run accepted")
	}
	var tableCount int
	if e := s.DB.QueryRow(ctx, "SELECT count(*) FROM pg_tables WHERE schemaname=current_schema()").Scan(&tableCount); e != nil || tableCount != 1 {
		t.Fatal("sandbox test must have only its own job table", e)
	}
}
