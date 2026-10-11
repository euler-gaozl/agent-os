package platform

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestSnapshotPinsResourceVersions(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	skill, e := s.PutResource(ctx, "skill", "method", JSON(Skill{Name: "method", Content: "original method"}))
	if e != nil {
		t.Fatal(e)
	}
	a := basicSnapshot("http://127.0.0.1").Agent
	a.Skills = []Ref{{ID: skill.ID, Revision: skill.Revision}}
	resource, e := s.PutResource(ctx, "agent", "research", JSON(a))
	if e != nil {
		t.Fatal(e)
	}
	snap, e := s.Snapshot(ctx, Ref{ID: resource.ID, Revision: resource.Revision}, 0)
	if e != nil {
		t.Fatal(e)
	}
	id := submit(t, s, snap)
	if _, e = s.PutResource(ctx, "skill", "method", JSON(Skill{Name: "method", Content: "changed method"})); e != nil {
		t.Fatal(e)
	}
	restored, e := s.Run(ctx, id)
	if e != nil || restored.Snapshot.Skills[0].Content != "original method" {
		t.Fatal("running task changed when skill was edited", e)
	}
}
func TestLegacyCompactionRetainsOriginalAndConstraints(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		completion(w, Message{Role: "assistant", Content: "Fixture summary: source discrepancy remains unresolved; original evidence can be retrieved."})
	}))
	defer model.Close()
	snap := basicSnapshot(model.URL)
	snap.Agent.ContextBytes = 4096
	submit(t, s, snap)
	r := claim(t, s, "one")
	r.State.Messages = []Message{{Role: "user", Content: r.Task}, {Role: "assistant", Content: strings.Repeat("original-only-evidence;", 300)}, {Role: "user", Content: "Keep unresolved sample changes visible."}, {Role: "assistant", ToolCalls: []ToolCall{{ID: "lookup", Type: "function", Function: FunctionCall{Name: "knowledge_search", Arguments: `{"query":"evidence"}`}}}}, {Role: "tool", ToolCallID: "lookup", Content: "fixture source"}}
	if e := s.Compact(ctx, &r); e != nil {
		t.Fatal(e)
	}
	restored, e := s.Run(ctx, r.ID)
	if e != nil {
		t.Fatal(e)
	}
	if !strings.Contains(SystemMessage(restored).Content, "Do not predict prices.") {
		t.Fatal("pinned constraint lost")
	}
	if !strings.Contains(string(JSON(restored.State.Messages)), "Full transcript artifact") {
		t.Fatal("original transcript entry point lost")
	}
	var body []byte
	if e = s.DB.QueryRow(ctx, "SELECT a.body FROM artifacts a JOIN artifact_refs r ON r.hash=a.hash WHERE r.root=$1", "run:"+r.ID).Scan(&body); e != nil || !strings.Contains(string(body), "original-only-evidence") {
		t.Fatal("original evidence lost", e)
	}
	if !strings.Contains(string(JSON(restored.State.Messages)), "lookup") {
		t.Fatal("tool call/result pairing lost")
	}
}
func TestModelTruncationCannotDriveTools(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		jsonResponse(w, 200, map[string]any{"choices": []any{map[string]any{"message": Message{Role: "assistant", ToolCalls: []ToolCall{{ID: "call1", Type: "function", Function: FunctionCall{Name: "note_save", Arguments: `{}`}}}}, "finish_reason": "length"}}})
	}))
	defer model.Close()
	submit(t, s, basicSnapshot(model.URL))
	r := claim(t, s, "one")
	worker := Worker{Store: s, ID: r.Owner, Lease: 10 * time.Second}
	worker.execute(ctx, r)
	restored, e := s.Run(ctx, r.ID)
	if e != nil || restored.Status != "failed" {
		t.Fatal("truncated response accepted", e)
	}
	var effects int
	s.DB.QueryRow(ctx, "SELECT count(*) FROM documents").Scan(&effects)
	if effects != 0 {
		t.Fatal("truncated model plan had effects")
	}
}
func TestLegacyFinalOutputCheckpointResumesWithoutModel(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	var count atomic.Int32
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count.Add(1)
		completion(w, Message{Role: "assistant", Content: "should not be called"})
	}))
	defer model.Close()
	submit(t, s, basicSnapshot(model.URL))
	r := claim(t, s, "old")
	_, _ = s.DB.Exec(ctx, "UPDATE runs SET engine='legacy-go' WHERE id=$1", r.ID)
	r.Engine = "legacy-go"
	r.Step = 1
	r.State.PlanRevision = r.RuleRevision
	r.State.Messages = append(r.State.Messages, Message{Role: "assistant", Content: "already durable"})
	if e := s.Save(ctx, r, "running"); e != nil {
		t.Fatal(e)
	}
	s.DB.Exec(ctx, "UPDATE runs SET lease_until=now()-interval '1 second' WHERE id=$1", r.ID)
	r = claim(t, s, "new")
	worker := Worker{Store: s, ID: "new", Lease: 10 * time.Second}
	worker.execute(ctx, r)
	done, e := s.Run(ctx, r.ID)
	if e != nil || done.Status != "completed" || done.State.Result != "already durable" || count.Load() != 0 {
		t.Fatal("recovery called model again", e)
	}
}
func TestEncryptedCredentialsAndNameBinding(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	t.Setenv("MASTER_KEY", strings.Repeat("fixture-master-key", 4))
	if e := s.PutSecret(ctx, "FIXTURE_API_KEY", "fixture-private-value"); e != nil {
		t.Fatal(e)
	}
	var sealed []byte
	s.DB.QueryRow(ctx, "SELECT sealed FROM secrets WHERE name='FIXTURE_API_KEY'").Scan(&sealed)
	if strings.Contains(string(sealed), "fixture-private-value") {
		t.Fatal("plaintext stored")
	}
	value, e := s.Secret(ctx, "FIXTURE_API_KEY")
	if e != nil || value != "fixture-private-value" {
		t.Fatal("cannot decrypt own secret", e)
	}
	s.DB.Exec(ctx, "UPDATE secrets SET name='RENAMED_API_KEY' WHERE name='FIXTURE_API_KEY'")
	if _, e = s.Secret(ctx, "RENAMED_API_KEY"); e == nil {
		t.Fatal("credential ciphertext was not bound to reference name")
	}
}
func TestMemoryScopeAndExpiry(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	expired := time.Now().Add(-time.Hour)
	for _, d := range []Document{{Kind: "memory", Title: "alpha", Content: "alpha policy", Source: "test", Scope: "alpha"}, {Kind: "memory", Title: "beta", Content: "beta policy", Source: "test", Scope: "beta"}, {Kind: "memory", Title: "expired", Content: "obsolete policy", Source: "test", Scope: "alpha", ValidUntil: &expired}} {
		if _, e := s.PutDocument(ctx, d); e != nil {
			t.Fatal(e)
		}
	}
	docs, e := searchDocuments(ctx, s.DB, "policy", "memory", "alpha")
	if e != nil || len(docs) != 1 || docs[0].Title != "alpha" {
		t.Fatal("memory scope/expiry incorrect", e)
	}
}
func TestArtifactPagingRetainsReadableContent(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	snap := basicSnapshot("http://127.0.0.1")
	snap.Agent.Tools = append(snap.Agent.Tools, "artifact_read")
	submit(t, s, snap)
	r := claim(t, s, "one")
	hash, e := s.PutArtifact(ctx, []byte(strings.Repeat("来源证据", 3000)), "text/plain", "run:"+r.ID)
	if e != nil {
		t.Fatal(e)
	}
	inv := invocation(r)
	inv.Name = "artifact_read"
	inv.Arguments = JSON(map[string]any{"hash": hash, "offset": 0, "limit": 1200})
	b, e := s.LocalTool(ctx, inv)
	if e != nil {
		t.Fatal(e)
	}
	var result struct {
		Content string `json:"content"`
		Next    int    `json:"next_offset"`
		More    bool   `json:"has_more"`
	}
	if e = json.Unmarshal(b, &result); e != nil {
		t.Fatal(e)
	}
	if len(b) > 6000 || len([]rune(result.Content)) != 1200 || result.Next != 1200 || !result.More {
		t.Fatal("artifact page cannot be included in model context")
	}
}
func TestCancellationPreservesUnknownExternalOutcome(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	snap := basicSnapshot("http://127.0.0.1")
	snap.Connectors = []Connector{{Name: "remote", Endpoint: "https://example.invalid", Tools: []Tool{tool("write", "test", `{"type":"object"}`)}}}
	submit(t, s, snap)
	r := claim(t, s, "one")
	inv := invocation(r)
	inv.Name = "mcp_remote_write"
	inv.Arguments = json.RawMessage(`{}`)
	tx, e := s.DB.Begin(ctx)
	if e != nil {
		t.Fatal(e)
	}
	if e = insertCall(ctx, tx, inv, "inflight", nil); e != nil {
		t.Fatal(e)
	}
	tx.Commit(ctx)
	if e = s.Cancel(ctx, r.ID); e != nil {
		t.Fatal(e)
	}
	worker := Worker{Store: s, Lease: 10 * time.Second}
	worker.execute(ctx, r)
	restored, e := s.Run(ctx, r.ID)
	if e != nil || restored.Status != "waiting_unknown" {
		t.Fatal("cancel hid unresolved external effect", e)
	}
	if e = s.Resolve(ctx, r.ID, inv.OperationID, "completed", "verified receipt", json.RawMessage(`{}`)); e != nil {
		t.Fatal(e)
	}
	restored, _ = s.Run(ctx, r.ID)
	if restored.Status != "cancelled" {
		t.Fatal("reconciled cancellation unexpectedly resumed")
	}
}
func TestTelemetryFailureDoesNotBlockExecution(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	t.Setenv("LANGFUSE_PUBLIC_KEY", "fixture-public")
	t.Setenv("LANGFUSE_SECRET_KEY", "fixture-secret")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(503) }))
	defer server.Close()
	submit(t, s, basicSnapshot("http://127.0.0.1"))
	if e := s.exportOne(ctx, server.URL); e == nil {
		t.Fatal("failed exporter claimed success")
	}
	r := claim(t, s, "one")
	if _, e := s.LocalTool(ctx, invocation(r)); e != nil {
		t.Fatal("telemetry failure blocked execution", e)
	}
	var exports int
	s.DB.QueryRow(ctx, "SELECT count(*) FROM telemetry_exports").Scan(&exports)
	if exports != 0 {
		t.Fatal("unexported event marked delivered")
	}
}
