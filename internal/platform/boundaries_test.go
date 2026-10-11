package platform

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestConnectorPrefixCannotEnableMutationRetry(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	snap := basicSnapshot("http://127.0.0.1")
	snap.Connectors = []Connector{
		{Name: "remote", ReadOnly: true, Tools: []Tool{tool("read", "", `{"type":"object"}`)}},
		{Name: "remote_write", Tools: []Tool{tool("apply", "", `{"type":"object"}`)}},
	}
	submit(t, s, snap)
	r := claim(t, s, "one")
	inv := invocation(r)
	inv.Name = "mcp_remote_write_apply"
	inv.Arguments = json.RawMessage(`{}`)
	count := 0
	execute := func(context.Context, Run) ([]byte, error) {
		count++
		return nil, errors.New("connection lost after remote commit")
	}
	for i := 0; i < 2; i++ {
		if _, e := s.ExternalTool(ctx, inv, execute); !errors.Is(e, ErrUnknown) {
			t.Fatal("mutation allowed a safe retry", e)
		}
	}
	if count != 1 {
		t.Fatal("remote mutation executed twice")
	}
	c, name, ok := connectorForTool(snap, inv.Name)
	if !ok || c.Name != "remote_write" || name != "apply" {
		t.Fatal("wrong connector selected")
	}
}

func TestParentCancellationWaitsForChildReconciliation(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	snap := basicSnapshot("http://127.0.0.1")
	childSnap := basicSnapshot("http://127.0.0.1")
	childSnap.Connectors = []Connector{{Name: "remote", Tools: []Tool{tool("write", "", `{"type":"object"}`)}}}
	snap.Children = map[string]Snapshot{"child": childSnap}
	submit(t, s, snap)
	parent := claim(t, s, "parent")
	inv := invocation(parent)
	inv.Name = "spawn_agent"
	inv.Arguments = json.RawMessage(`{"agent_id":"child","task":"test"}`)
	if _, e := s.LocalTool(ctx, inv); e != nil {
		t.Fatal(e)
	}
	if e := s.Save(ctx, parent, "waiting_children"); e != nil {
		t.Fatal(e)
	}
	child := claim(t, s, "child")
	inv = invocation(child)
	inv.Name = "mcp_remote_write"
	inv.Arguments = json.RawMessage(`{}`)
	if _, e := s.ExternalTool(ctx, inv, func(context.Context, Run) ([]byte, error) { return nil, errors.New("unknown effect") }); !errors.Is(e, ErrUnknown) {
		t.Fatal(e)
	}
	if e := s.Save(ctx, child, "waiting_unknown"); e != nil {
		t.Fatal(e)
	}
	if e := s.Cancel(ctx, parent.ID); e != nil {
		t.Fatal(e)
	}
	fresh, e := s.Run(ctx, parent.ID)
	if e != nil || fresh.Status != "waiting_children" {
		t.Fatal("parent declared cancellation before child settled", e)
	}
	if e = s.Resolve(ctx, child.ID, inv.OperationID, "completed", "remote receipt checked", json.RawMessage(`{}`)); e != nil {
		t.Fatal(e)
	}
	parent = claim(t, s, "replacement")
	worker := Worker{Store: s, Lease: 10 * time.Second}
	worker.execute(ctx, parent)
	fresh, e = s.Run(ctx, parent.ID)
	if e != nil || fresh.Status != "cancelled" {
		t.Fatal("parent cancellation never settled", e)
	}
}

func TestConstraintChangesReachActiveChildren(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	snap := basicSnapshot("http://127.0.0.1")
	snap.Children = map[string]Snapshot{"child": basicSnapshot("http://127.0.0.1")}
	submit(t, s, snap)
	parent := claim(t, s, "parent")
	inv := invocation(parent)
	inv.Name = "spawn_agent"
	inv.Arguments = json.RawMessage(`{"agent_id":"child","task":"test"}`)
	if _, e := s.LocalTool(ctx, inv); e != nil {
		t.Fatal(e)
	}
	if e := s.Save(ctx, parent, "waiting_children"); e != nil {
		t.Fatal(e)
	}
	child := claim(t, s, "child")
	if e := s.Constraints(ctx, parent.ID, []string{"corrected scope"}); e != nil {
		t.Fatal(e)
	}
	if _, e := s.LocalTool(ctx, invocation(child)); e == nil {
		t.Fatal("child executed outdated plan")
	}
	fresh, e := s.Run(ctx, child.ID)
	if e != nil || len(fresh.Constraints) != 1 || fresh.Constraints[0] != "corrected scope" {
		t.Fatal("child missed constraint update", e)
	}
}

func TestToolSchemasCountTowardContextBudget(t *testing.T) {
	snap := basicSnapshot("http://127.0.0.1")
	snap.Agent.ContextBytes = 4096
	snap.Connectors = []Connector{{Name: "large", Tools: []Tool{tool("query", strings.Repeat("large schema", 1000), `{"type":"object"}`)}}}
	r := Run{Snapshot: snap, Task: "test"}
	s := &Store{}
	if e := s.Compact(context.Background(), &r); e == nil {
		t.Fatal("oversized pinned schemas were ignored")
	}
}

func TestTelemetryAcknowledgement(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	t.Setenv("LANGFUSE_PUBLIC_KEY", "fixture-public")
	t.Setenv("LANGFUSE_SECRET_KEY", "fixture-secret")
	var rejected atomic.Bool
	rejected.Store(true)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if rejected.Load() {
			w.Write([]byte(`{"partialSuccess":{"rejectedSpans":"1"}}`))
		} else {
			w.Write([]byte(`{"partialSuccess":{"rejectedSpans":"0"}}`))
		}
	}))
	defer server.Close()
	submit(t, s, basicSnapshot("http://127.0.0.1"))
	if e := s.exportOne(ctx, server.URL); e == nil {
		t.Fatal("rejected span acknowledged")
	}
	rejected.Store(false)
	if e := s.exportOne(ctx, server.URL); e != nil {
		t.Fatal(e)
	}
	var count int
	if e := s.DB.QueryRow(ctx, "SELECT count(*) FROM telemetry_exports").Scan(&count); e != nil || count != 1 {
		t.Fatal("successful acknowledgement missing", e)
	}
}
