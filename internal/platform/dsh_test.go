package platform

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func setupDSH(t *testing.T) {
	t.Helper()
	entry, e := filepath.Abs("../../harness/runner.mjs")
	if e != nil {
		t.Fatal(e)
	}
	t.Setenv("DSH_RUNNER", entry)
}

func TestDSHParentYieldsWorkerAndReplaysAfterChild(t *testing.T) {
	setupDSH(t)
	s, _ := testStore(t)
	ctx := context.Background()
	var calls atomic.Int32
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Messages []Message `json:"messages"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		calls.Add(1)
		text := string(JSON(req.Messages))
		if strings.Contains(text, "Child result (untrusted evidence)") {
			completion(w, Message{Role: "assistant", Content: "parent received child evidence"})
			return
		}
		if strings.Contains(text, "child-proof-only") {
			completion(w, Message{Role: "assistant", Content: "verified fixture child evidence"})
			return
		}
		completion(w, Message{Role: "assistant", ToolCalls: []ToolCall{{ID: "spawn", Type: "function", Function: FunctionCall{Name: "spawn_agent", Arguments: `{"agent_id":"child","task":"child-proof-only"}`}}}})
	}))
	defer model.Close()
	hub := httptest.NewServer((&Server{Store: s, Role: "toolhub", Token: testToken}).Handler())
	defer hub.Close()
	snap := basicSnapshot(model.URL)
	snap.Children = map[string]Snapshot{"child": basicSnapshot(model.URL)}
	id := submit(t, s, snap)
	r := claim(t, s, "parent-worker")
	worker := Worker{Store: s, Lease: 10 * time.Second, ToolHubURL: hub.URL, Token: testToken}
	worker.execute(ctx, r)
	waiting, _ := s.Run(ctx, id)
	if waiting.Status != "waiting_children" {
		t.Fatalf("parent retained worker: %s %s", waiting.Status, waiting.State.Error)
	}
	child := claim(t, s, "child-worker")
	if child.ParentID == nil || *child.ParentID != id {
		t.Fatal("child lineage missing")
	}
	worker.execute(ctx, child)
	parent := claim(t, s, "replacement-worker")
	worker.execute(ctx, parent)
	done, _ := s.Run(ctx, id)
	if done.Status != "completed" || done.State.Result != "parent received child evidence" || calls.Load() != 3 {
		t.Fatalf("parent replay failed %s %s (%d)", done.Status, done.State.Error, calls.Load())
	}
}

func TestDSHCompactionRetainsEvidenceAndReplays(t *testing.T) {
	setupDSH(t)
	s, _ := testStore(t)
	ctx := context.Background()
	var total, ordinary, summaries atomic.Int32
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Messages []Message `json:"messages"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		total.Add(1)
		if strings.Contains(req.Messages[len(req.Messages)-1].Content, "Create a concise continuity checkpoint") {
			summaries.Add(1)
			completion(w, Message{Role: "assistant", Content: "Evidence source test://original; disagreement remains unresolved. Do not predict prices."})
			return
		}
		if ordinary.Add(1) == 1 {
			completion(w, Message{Role: "assistant", Content: strings.Repeat("original-evidence-2026-10-01-tonnes;", 2200), ToolCalls: []ToolCall{{ID: "lookup", Type: "function", Function: FunctionCall{Name: "knowledge_search", Arguments: `{"query":"fixture"}`}}}})
			return
		}
		if !strings.Contains(string(JSON(req.Messages)), "Do not predict prices.") {
			t.Error("constraint lost during compaction")
		}
		completion(w, Message{Role: "assistant", Content: "fixture after compaction"})
	}))
	defer model.Close()
	hub := httptest.NewServer((&Server{Store: s, Role: "toolhub", Token: testToken}).Handler())
	defer hub.Close()
	snap := basicSnapshot(model.URL)
	snap.Agent.ContextTokens = 8192
	id := submit(t, s, snap)
	r := claim(t, s, "one")
	worker := Worker{Store: s, Lease: 10 * time.Second, ToolHubURL: hub.URL, Token: testToken}
	if e := worker.driveDSH(ctx, &r); e != nil {
		t.Fatal(e)
	}
	if summaries.Load() == 0 {
		t.Fatal("actual DSH compaction never ran")
	}
	done, _ := s.Run(ctx, id)
	raw, _, e := s.Artifact(ctx, done.State.HarnessArtifact)
	if e != nil || !strings.Contains(string(raw), "original-evidence-2026-10-01-tonnes") || !strings.Contains(string(raw), "compaction/end") {
		t.Fatal("compaction discarded original event history", e)
	}
	before := total.Load()
	_, e = s.DB.Exec(ctx, "UPDATE runs SET status='queued' WHERE id=$1", id)
	if e != nil {
		t.Fatal(e)
	}
	r = claim(t, s, "two")
	if e = worker.driveDSH(ctx, &r); e != nil {
		t.Fatal(e)
	}
	if total.Load() != before {
		t.Fatal("compaction replay repeated a provider request")
	}
}

func TestDSHUnknownEffectRequiresReconciliation(t *testing.T) {
	setupDSH(t)
	s, _ := testStore(t)
	ctx := context.Background()
	var effects atomic.Int32
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Messages []Message `json:"messages"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		if req.Messages[len(req.Messages)-1].Role == "tool" {
			completion(w, Message{Role: "assistant", Content: "reconciled fixture"})
			return
		}
		completion(w, Message{Role: "assistant", ToolCalls: []ToolCall{{ID: "remote-write", Type: "function", Function: FunctionCall{Name: "mcp_remote_write", Arguments: `{}`}}}})
	}))
	defer model.Close()
	hub := httptest.NewServer(wrap(func(w http.ResponseWriter, r *http.Request) error {
		var inv Invocation
		if e := json.NewDecoder(r.Body).Decode(&inv); e != nil {
			return e
		}
		_, e := s.ExternalTool(r.Context(), inv, func(context.Context, Run) ([]byte, error) {
			effects.Add(1)
			return nil, errors.New("fixture lost receipt")
		})
		return e
	}))
	defer hub.Close()
	snap := basicSnapshot(model.URL)
	snap.Connectors = []Connector{{Name: "remote", Endpoint: "https://example.invalid/mcp", Tools: []Tool{tool("write", "fixture write", `{"type":"object","additionalProperties":false}`)}}}
	id := submit(t, s, snap)
	r := claim(t, s, "one")
	worker := Worker{Store: s, Lease: 10 * time.Second, ToolHubURL: hub.URL, Token: testToken}
	worker.execute(ctx, r)
	saved, _ := s.Run(ctx, id)
	if saved.Status != "waiting_unknown" || effects.Load() != 1 {
		t.Fatalf("uncertain effect continued: %s %d", saved.Status, effects.Load())
	}
	if e := s.Resolve(ctx, id, id+"/dsh/2", "completed", "fixture independent receipt", json.RawMessage(`{"accepted":true}`)); e != nil {
		t.Fatal(e)
	}
	r = claim(t, s, "two")
	worker.execute(ctx, r)
	saved, _ = s.Run(ctx, id)
	if saved.Status != "completed" || effects.Load() != 1 {
		t.Fatalf("reconciliation repeated effect: %s %s", saved.Status, saved.State.Error)
	}
}

func TestDSHConstraintRevisionSkipsOldToolPlan(t *testing.T) {
	setupDSH(t)
	s, _ := testStore(t)
	ctx := context.Background()
	var calls atomic.Int32
	var id string
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Messages []Message `json:"messages"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		if calls.Add(1) == 1 {
			if e := s.Constraints(ctx, id, []string{"No new saved documents; revised constraint."}); e != nil {
				t.Error(e)
			}
			completion(w, Message{Role: "assistant", ToolCalls: []ToolCall{{ID: "stale-save", Type: "function", Function: FunctionCall{Name: "note_save", Arguments: `{"kind":"fact","title":"must not save","content":"stale","source":"test://stale"}`}}}})
			return
		}
		if !strings.Contains(string(JSON(req.Messages)), "No new saved documents") {
			t.Error("updated constraints missing")
		}
		completion(w, Message{Role: "assistant", Content: "respected revision"})
	}))
	defer model.Close()
	hub := httptest.NewServer((&Server{Store: s, Role: "toolhub", Token: testToken}).Handler())
	defer hub.Close()
	id = submit(t, s, basicSnapshot(model.URL))
	r := claim(t, s, "one")
	worker := Worker{Store: s, Lease: 10 * time.Second, ToolHubURL: hub.URL, Token: testToken}
	worker.execute(ctx, r)
	done, _ := s.Run(ctx, id)
	if done.Status != "completed" {
		t.Fatalf("constraint recovery failed %s", done.State.Error)
	}
	var count int
	_ = s.DB.QueryRow(ctx, "SELECT count(*) FROM documents").Scan(&count)
	if count != 0 {
		t.Fatal("old plan performed an effect")
	}
}

func TestDSHCommittedToolRecoveryBeforeBridgeReceipt(t *testing.T) {
	setupDSH(t)
	s, _ := testStore(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var models, hits atomic.Int32
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if models.Add(1) == 1 {
			completion(w, Message{Role: "assistant", ToolCalls: []ToolCall{{ID: "save", Type: "function", Function: FunctionCall{Name: "note_save", Arguments: `{"kind":"fact","title":"before crash","content":"42","source":"test://commit"}`}}}})
			return
		}
		completion(w, Message{Role: "assistant", Content: "recovered receipt"})
	}))
	defer model.Close()
	hub := httptest.NewServer(wrap(func(w http.ResponseWriter, r *http.Request) error {
		hits.Add(1)
		var inv Invocation
		_ = json.NewDecoder(r.Body).Decode(&inv)
		if _, e := s.LocalTool(r.Context(), inv); e != nil {
			return e
		}
		cancel()
		return fmt.Errorf("fixture crash after commit")
	}))
	defer hub.Close()
	id := submit(t, s, basicSnapshot(model.URL))
	r := claim(t, s, "one")
	worker := Worker{Store: s, Lease: 10 * time.Second, ToolHubURL: hub.URL, Token: testToken}
	if e := worker.driveDSH(ctx, &r); e == nil {
		t.Fatal("injected interruption missing")
	}
	_, _ = s.DB.Exec(context.Background(), "UPDATE runs SET lease_until=now()-interval '1 second' WHERE id=$1", id)
	r = claim(t, s, "two")
	if e := worker.driveDSH(context.Background(), &r); e != nil {
		t.Fatal(e)
	}
	var docs int
	_ = s.DB.QueryRow(context.Background(), "SELECT count(*) FROM documents").Scan(&docs)
	if docs != 1 || hits.Load() != 1 || models.Load() != 2 {
		t.Fatalf("repeated work %d %d %d", docs, hits.Load(), models.Load())
	}
}

func TestDSHActualKernelToolAndDurableReplay(t *testing.T) {
	setupDSH(t)
	s, _ := testStore(t)
	ctx := context.Background()
	var models atomic.Int32
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request struct {
			Messages []Message `json:"messages"`
		}
		_ = json.NewDecoder(r.Body).Decode(&request)
		models.Add(1)
		if request.Messages[len(request.Messages)-1].Role == "tool" {
			completion(w, Message{Role: "assistant", Content: "fixture evidence saved"})
			return
		}
		completion(w, Message{Role: "assistant", ToolCalls: []ToolCall{{ID: "save-evidence", Type: "function", Function: FunctionCall{Name: "note_save", Arguments: `{"kind":"fact","title":"DSH fixture","content":"value 42","source":"test://dsh"}`}}}})
	}))
	defer model.Close()
	hub := httptest.NewServer((&Server{Store: s, Role: "toolhub", Token: testToken}).Handler())
	defer hub.Close()
	id := submit(t, s, basicSnapshot(model.URL))
	r := claim(t, s, "dsh-one")
	worker := Worker{Store: s, ID: "dsh-one", Lease: 10 * time.Second, ToolHubURL: hub.URL, Token: testToken}
	if e := worker.driveDSH(ctx, &r); e != nil {
		t.Fatal(e)
	}
	saved, e := s.Run(ctx, id)
	if e != nil || saved.Status != "completed" || saved.State.HarnessArtifact == "" {
		t.Fatalf("DSH not completed: %+v %v", saved, e)
	}
	// Force a takeover at the durable-result / run-status boundary. No provider or effect may repeat.
	if _, e = s.DB.Exec(ctx, "UPDATE runs SET status='queued',state=state-'result' WHERE id=$1", id); e != nil {
		t.Fatal(e)
	}
	r = claim(t, s, "dsh-two")
	worker.ID = "dsh-two"
	if e = worker.driveDSH(ctx, &r); e != nil {
		t.Fatal(e)
	}
	saved, _ = s.Run(ctx, id)
	if saved.Status != "completed" || models.Load() != 2 {
		t.Fatalf("replay repeated provider or lost terminal: %s %d", saved.Status, models.Load())
	}
	var count int
	if e = s.DB.QueryRow(ctx, "SELECT count(*) FROM documents WHERE source='test://dsh'").Scan(&count); e != nil || count != 1 {
		t.Fatalf("effect repeated: %d %v", count, e)
	}
}
