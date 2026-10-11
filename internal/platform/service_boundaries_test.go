package platform

import (
	"bytes"
	"context"
	"github.com/euler-gaozl/agent-os/internal/serviceclient"
	"github.com/euler-gaozl/agent-os/internal/servicehttp"
	kbservice "github.com/euler-gaozl/agent-os/services/knowledge"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestLegacyKnowledgeDocumentUsesBoundKnowledgeReader(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	ref := testKB(t, s, "legacy", KnowledgeBase{Name: "Legacy", Engine: "local"})
	file, e := s.UploadKnowledge(ctx, ref, "legacy.txt", "fixture://legacy", []byte("Retained historical source."))
	if e != nil {
		t.Fatal(e)
	}
	snap := basicSnapshot("http://127.0.0.1")
	snap.Agent.Tools = append(snap.Agent.Tools, "document_read")
	snap.Agent.Knowledge = []Ref{ref}
	snap.Knowledge = map[string]KnowledgeBase{ref.ID: {Name: "Legacy", Engine: "local"}}
	submit(t, s, snap)
	run := claim(t, s, "reader")
	token := strings.Repeat("t", 40)
	kb := httptest.NewServer((&kbservice.Server{Store: &kbservice.Store{DB: s.DB, RunReader: s}, HTTP: servicehttp.Config{Role: "knowledge", Token: token}}).Handler())
	defer kb.Close()
	s.Remote = &serviceclient.Client{}
	runtime := (&Server{Store: s, Token: token, KnowledgeURL: kb.URL}).RuntimeHandler(servicehttp.Config{Role: "runtime", Token: token})
	inv := invocation(run)
	inv.Name = "document_read"
	inv.Arguments = JSON(map[string]any{"id": file.DocumentID, "limit": 100})
	r := httptest.NewRequest(http.MethodPost, "/invoke", bytes.NewReader(JSON(inv)))
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	runtime.ServeHTTP(w, r)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "Retained historical source") {
		t.Fatal(w.Code, w.Body.String())
	}
	// The old copy still exists in the execution schema; it must not override
	// knowledge-bound authorization or become a globally readable local note.
	if _, e = s.LocalTool(ctx, Invocation{RunID: run.ID, Owner: run.Owner, Fence: run.Fence, RuleRevision: run.RuleRevision, OperationID: run.ID + "/tool/other", Name: "document_read", Arguments: inv.Arguments}); e == nil {
		t.Fatal("knowledge copy read as global execution document")
	}
}
