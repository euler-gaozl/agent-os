package main

import (
	"context"
	"encoding/json"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/euler-gaozl/agent-os/internal/contracts"
	"github.com/euler-gaozl/agent-os/internal/platform"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestRuntimeNoteUpgradeWithManagedRolePrivileges(t *testing.T) {
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
	name := "agentos_notes_roles_" + contracts.ID()
	if _, e = admin.Exec(ctx, "CREATE DATABASE "+pgx.Identifier{name}.Sanitize()); e != nil {
		t.Fatal(e)
	}
	created := []string{}
	defer func() {
		if _, e = admin.Exec(ctx, "DROP DATABASE "+pgx.Identifier{name}.Sanitize()+" WITH (FORCE)"); e != nil {
			t.Error(e)
		}
		for _, role := range created {
			if _, e = admin.Exec(ctx, "DROP ROLE "+pgx.Identifier{role}.Sanitize()); e != nil {
				t.Error(e)
			}
		}
	}()
	for _, role := range []string{"agentos_runtime", "agentos_worker"} {
		var exists bool
		if e = admin.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=$1)", role).Scan(&exists); e != nil {
			t.Fatal(e)
		}
		if !exists {
			if _, e = admin.Exec(ctx, "CREATE ROLE "+pgx.Identifier{role}.Sanitize()); e != nil {
				t.Fatal(e)
			}
			created = append(created, role)
		}
	}
	u, e := url.Parse(base)
	if e != nil {
		t.Fatal(e)
	}
	u.Path = "/" + name
	q := u.Query()
	q.Set("search_path", "public")
	u.RawQuery = q.Encode()
	if e = upgradeService(ctx, u.String(), "runtime"); e != nil {
		t.Fatal(e)
	}
	for _, role := range []string{"agentos_runtime", "agentos_worker"} {
		t.Run(role, func(t *testing.T) {
			cfg, e := pgxpool.ParseConfig(u.String())
			if e != nil {
				t.Fatal(e)
			}
			// SET ROLE on every physical connection exercises the deployed privileges;
			// using the migration owner's default role would conceal missing grants.
			cfg.AfterConnect = func(ctx context.Context, c *pgx.Conn) error {
				_, e := c.Exec(ctx, "SET ROLE "+pgx.Identifier{role}.Sanitize())
				return e
			}
			pool, e := pgxpool.NewWithConfig(ctx, cfg)
			if e != nil {
				t.Fatal(e)
			}
			defer pool.Close()
			s := &platform.Store{DB: pool}
			var actual string
			if e = pool.QueryRow(ctx, "SELECT current_user").Scan(&actual); e != nil || actual != role {
				t.Fatal(e, actual)
			}
			d, e := s.PutDocument(ctx, contracts.Document{Kind: "memory", Scope: "role-fixture", Title: "权限验收", Content: "original", Source: "fixture://role"})
			if e != nil {
				t.Fatal("restricted create/audit", e)
			}
			snap := contracts.Snapshot{AgentRef: contracts.Ref{ID: "role-fixture", Revision: 1}, Agent: contracts.Agent{Name: "fixture", Prompt: "fixture", Tools: []string{"note_revise", "note_retire"}, MaxSteps: 4, Model: contracts.ModelConfig{BaseURL: "https://example.invalid", Model: "fixture"}}}
			if _, e = s.Submit(ctx, contracts.ID(), "role acceptance", snap, nil); e != nil {
				t.Fatal(e)
			}
			r, e := s.Claim(ctx, role, 10*time.Second)
			if e != nil {
				t.Fatal(e)
			}
			inv := contracts.Invocation{RunID: r.ID, Owner: r.Owner, Fence: r.Fence, RuleRevision: r.RuleRevision, OperationID: r.ID + "/revise", Name: "note_revise", Arguments: contracts.JSON(platform.NoteRevision{ExpectedCurrentID: d.ID, Title: d.Title, Content: "corrected", Source: d.Source, Reason: "fixture"})}
			body, e := s.LocalTool(ctx, inv)
			if e != nil {
				t.Fatal("restricted revision", e)
			}
			var result struct{ Document contracts.Document }
			if e = json.Unmarshal(body, &result); e != nil || result.Document.ID == "" {
				t.Fatal(e, string(body))
			}
			inv.Name = "note_retire"
			inv.OperationID = r.ID + "/retire"
			inv.Arguments = contracts.JSON(platform.NoteRetirement{ExpectedCurrentID: result.Document.ID, Reason: "fixture withdrawal"})
			if _, e = s.LocalTool(ctx, inv); e != nil {
				t.Fatal("restricted retirement", e)
			}
			var audit int
			if e = pool.QueryRow(ctx, "SELECT count(*) FROM note_audits WHERE root_id=$1", d.ID).Scan(&audit); e != nil || audit != 3 {
				t.Fatal("restricted audit", audit, e)
			}
		})
	}
}
