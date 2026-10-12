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

	"github.com/euler-gaozl/agent-os/internal/serviceclient"
	"github.com/euler-gaozl/agent-os/internal/servicehttp"
	hubservice "github.com/euler-gaozl/agent-os/services/toolhub"
)

func TestDSHNoteConflictIsDurableKnownRejectionThroughServices(t *testing.T) {
	setupDSH(t)
	s, _ := testStore(t)
	ctx := context.Background()
	original, e := s.PutDocument(ctx, Document{Kind: "fact", Scope: "test", Title: "fixture", Content: "initial", Source: "fixture://notes"})
	if e != nil {
		t.Fatal(e)
	}
	updated := original
	updated.ID = ""
	updated.Supersedes = &original.ID
	updated.Content = "already corrected"
	if _, e = s.PutDocument(ctx, updated); e != nil {
		t.Fatal(e)
	}
	var requests atomic.Int32
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in struct{ Messages []Message }
		if e := json.NewDecoder(r.Body).Decode(&in); e != nil {
			t.Error(e)
		}
		requests.Add(1)
		last := in.Messages[len(in.Messages)-1]
		if last.Role == "tool" {
			// Source conflict is delivered to the model as a completed, no-effect receipt.
			if !strings.Contains(last.Content, "conflict") || !strings.Contains(last.Content, "changed") {
				t.Error("missing known rejection", last.Content)
			}
			completion(w, Message{Role: "assistant", Content: "并发修订已明确拒绝，没有覆盖当前资料。"})
			return
		}
		completion(w, Message{Role: "assistant", ToolCalls: []ToolCall{{ID: "stale-revision", Type: "function", Function: FunctionCall{Name: "note_revise", Arguments: string(JSON(revision(original)))}}}})
	}))
	defer model.Close()
	runtime := httptest.NewServer((&Server{Store: s}).RuntimeHandler(servicehttp.Config{Role: "runtime", Peers: map[string]string{"toolhub": servicehttp.TokenHash(testToken)}}))
	defer runtime.Close()
	hubStore := &hubservice.Store{DB: s.DB}
	hub := httptest.NewServer((&hubservice.Server{Store: hubStore, HTTP: servicehttp.Config{Role: "toolhub", Peers: map[string]string{"worker": servicehttp.TokenHash(testToken)}}, Execution: &serviceclient.Client{RuntimeURL: runtime.URL, Token: testToken}}).Handler())
	defer hub.Close()
	snap := basicSnapshot(model.URL)
	snap.Agent.Tools = append(snap.Agent.Tools, "note_revise")
	id := submit(t, s, snap)
	r := claim(t, s, "notes-worker")
	worker := Worker{Store: s, ID: r.Owner, Lease: 10 * time.Second, ToolHubURL: hub.URL, Token: testToken}
	if e = worker.driveDSH(ctx, &r); e != nil {
		t.Fatal(e)
	}
	run, e := s.Run(ctx, id)
	if e != nil || run.Status != "completed" {
		t.Fatal("known conflict wedged run", run.Status, e)
	}
	var receipts, unknown, audits int
	if e = s.DB.QueryRow(ctx, `SELECT (SELECT count(*) FROM calls WHERE run_id=$1 AND kind='tool' AND status='completed' AND response->>'outcome'='conflict'),(SELECT count(*) FROM calls WHERE run_id=$1 AND status='unknown'),(SELECT count(*) FROM note_audits WHERE run_id=$1)`, id).Scan(&receipts, &unknown, &audits); e != nil || receipts != 1 || unknown != 0 || audits != 0 {
		t.Fatal("rejection ledger", receipts, unknown, audits, e)
	}
	if _, e = s.DB.Exec(ctx, "UPDATE runs SET status='queued',state=state-'result' WHERE id=$1", id); e != nil {
		t.Fatal(e)
	}
	r = claim(t, s, "notes-replay")
	worker.ID = r.Owner
	if e = worker.driveDSH(ctx, &r); e != nil || requests.Load() != 2 {
		t.Fatal("rejection re-executed", e, requests.Load())
	}
}
