package platform

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func testKB(t *testing.T, s *Store, id string, kb KnowledgeBase) Ref {
	t.Helper()
	if e := kb.Validate(); e != nil {
		t.Fatal(e)
	}
	r, e := s.PutResource(context.Background(), "knowledge", id, JSON(kb))
	if e != nil {
		t.Fatal(e)
	}
	return Ref{ID: r.ID, Revision: r.Revision}
}
func TestKnowledgeUploadRetentionDedupAndVersionIsolation(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	ref := testKB(t, s, "research", KnowledgeBase{Name: "Research", Engine: "local"})
	body := []byte(strings.Repeat("样本库存变化仅为测试数据，不能作为期货事实。\n", 120))
	a, e := s.UploadKnowledge(ctx, ref, "fixture.md", "test://original", body)
	if e != nil {
		t.Fatal(e)
	}
	b, e := s.UploadKnowledge(ctx, ref, "fixture.md", "test://original", body)
	if e != nil || a.ID != b.ID {
		t.Fatal("duplicate document upload", e)
	}
	raw, _, e := s.Artifact(ctx, a.Hash)
	if e != nil || string(raw) != string(body) {
		t.Fatal("original bytes changed", e)
	}
	hits, e := s.Retrieve(ctx, ref, a.Config, "样本库存")
	if e != nil || len(hits.Hits) == 0 || hits.Hits[0]["source"] != "test://original" {
		t.Fatal("missing sourced retrieval", e)
	}
	next := testKB(t, s, "research", KnowledgeBase{Name: "Research revision", Engine: "local", ChunkSize: 600})
	hits, e = s.Retrieve(ctx, next, KnowledgeBase{Engine: "local"}, "样本库存")
	if e != nil || len(hits.Hits) != 0 {
		t.Fatal("index from another revision leaked", e)
	}
	if _, e = s.UploadKnowledge(ctx, ref, "unsupported.pdf", "test", []byte("%PDF-fixture")); e == nil {
		t.Fatal("unsupported parser silently accepted")
	}
}
func TestMilvusEmbeddingAndSourceBackreference(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	var mu sync.Mutex
	ids := []string{}
	requests := []string{}
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		requests = append(requests, r.URL.Path)
		switch r.URL.Path {
		case "/embeddings":
			var in struct {
				Input []string `json:"input"`
			}
			json.NewDecoder(r.Body).Decode(&in)
			data := []any{}
			for i := range in.Input {
				data = append(data, map[string]any{"index": i, "embedding": []float64{1, 0}})
			}
			jsonResponse(w, 200, map[string]any{"data": data})
		case "/v2/vectordb/collections/has":
			jsonResponse(w, 200, map[string]any{"code": 0, "data": map[string]bool{"has": false}})
		case "/v2/vectordb/collections/create":
			jsonResponse(w, 200, map[string]any{"code": 0, "data": map[string]any{}})
		case "/v2/vectordb/entities/upsert":
			var in struct {
				Data []struct {
					ID string `json:"id"`
				} `json:"data"`
			}
			json.NewDecoder(r.Body).Decode(&in)
			for _, d := range in.Data {
				ids = append(ids, d.ID)
			}
			jsonResponse(w, 200, map[string]any{"code": 0, "data": map[string]any{}})
		case "/v2/vectordb/entities/search":
			data := []any{}
			for _, id := range ids {
				data = append(data, map[string]any{"id": id, "distance": .9})
			}
			data = append(data, map[string]any{"id": "foreign-index-id", "distance": 1})
			jsonResponse(w, 200, map[string]any{"code": 0, "data": data})
		default:
			w.WriteHeader(404)
		}
	}))
	defer remote.Close()
	ref := testKB(t, s, "vectors", KnowledgeBase{Name: "Vectors", Engine: "milvus", Endpoint: remote.URL, Embedding: ModelConfig{BaseURL: remote.URL, Model: "fixture-embedding"}, Dimensions: 2})
	f, e := s.UploadKnowledge(ctx, ref, "fixture.txt", "test://milvus", []byte("fixture inventory, not actual data"))
	if e != nil {
		t.Fatal(e)
	}
	if e = s.indexFile(ctx, f.ID); e != nil {
		t.Fatal(e)
	}
	f, e = s.KnowledgeFile(ctx, f.ID)
	if e != nil || f.Status != "ready" {
		t.Fatal("index not committed", f.Error, e)
	}
	result, e := s.Retrieve(ctx, ref, f.Config, "inventory")
	if e != nil || len(result.Hits) != 1 || result.Hits[0]["document_id"] != f.DocumentID {
		t.Fatal("vector result not resolved to owned evidence", e)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(requests) < 5 {
		t.Fatal("missing adapter requests")
	}
}
func TestLightRAGTracksAsynchronousCompletionAndUnknownOutcome(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	var fileSource atomic.Value
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/documents/text":
			var input struct {
				FileSource string `json:"file_source"`
			}
			if e := json.NewDecoder(r.Body).Decode(&input); e != nil {
				t.Error(e)
			}
			fileSource.Store(input.FileSource)
			jsonResponse(w, 200, map[string]string{"track_id": "fixture-track"})
		case "/documents/track_status/fixture-track":
			jsonResponse(w, 200, map[string]any{"documents": []any{map[string]string{"status": "processed"}}})
		case "/query/data":
			jsonResponse(w, 200, map[string]any{"status": "success", "data": map[string]any{"chunks": []any{map[string]string{"content": "fixture graph evidence", "file_path": fileSource.Load().(string)}}, "entities": []any{}}})
		default:
			w.WriteHeader(404)
		}
	}))
	defer remote.Close()
	ref := testKB(t, s, "graph", KnowledgeBase{Name: "Graph", Engine: "lightrag", Endpoint: remote.URL})
	f, e := s.UploadKnowledge(ctx, ref, "fixture.txt", "test://graph", []byte("fixture graph evidence"))
	if e != nil {
		t.Fatal(e)
	}
	if e = s.indexFile(ctx, f.ID); e != nil {
		t.Fatal(e)
	}
	f, _ = s.KnowledgeFile(ctx, f.ID)
	if f.Status != "external_pending" {
		t.Fatal("HTTP receipt was incorrectly treated as indexed")
	}
	if e = s.indexFile(ctx, f.ID); e != nil {
		t.Fatal(e)
	}
	f, _ = s.KnowledgeFile(ctx, f.ID)
	if f.Status != "ready" {
		t.Fatal("external index completion not tracked")
	}
	result, e := s.Retrieve(ctx, ref, f.Config, "fixture")
	if e != nil || !strings.Contains(string(result.Graph), "fixture graph evidence") || !strings.Contains(string(result.Graph), f.DocumentID) {
		t.Fatal(e)
	}
	if _, e = s.DB.Exec(ctx, "UPDATE knowledge_files SET status='running',track_id='' WHERE id=$1", f.ID); e != nil {
		t.Fatal(e)
	}
	if e = s.indexFile(ctx, f.ID); e != nil {
		t.Fatal(e)
	}
	f, _ = s.KnowledgeFile(ctx, f.ID)
	if f.Status != "unknown" {
		t.Fatal("lost receipt was blindly replayed")
	}
}
func TestAgentUsesBoundKnowledgeService(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	ref := testKB(t, s, "bound", KnowledgeBase{Name: "Bound", Engine: "local"})
	f, e := s.UploadKnowledge(ctx, ref, "fixture.txt", "test://bound", []byte("可追溯库存，仅测试用途"))
	if e != nil {
		t.Fatal(e)
	}
	knowledge := httptest.NewServer((&Server{Store: s, Role: "knowledge", Token: testToken}).Handler())
	defer knowledge.Close()
	hub := httptest.NewServer((&Server{Store: s, Role: "toolhub", Token: testToken, KnowledgeURL: knowledge.URL}).Handler())
	defer hub.Close()
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request struct {
			Messages []Message `json:"messages"`
		}
		json.NewDecoder(r.Body).Decode(&request)
		for _, m := range request.Messages {
			if m.Role == "tool" {
				if !strings.Contains(m.Content, "test://bound") {
					t.Error("model did not receive source")
				}
				completion(w, Message{Role: "assistant", Content: "Fixture completed with source."})
				return
			}
		}
		completion(w, Message{Role: "assistant", ToolCalls: []ToolCall{{ID: "retrieve", Type: "function", Function: FunctionCall{Name: "kb_search", Arguments: `{"kb_id":"bound","query":"库存"}`}}}})
	}))
	defer model.Close()
	snap := basicSnapshot(model.URL)
	snap.Agent.Knowledge = []Ref{ref}
	snap.Knowledge = map[string]KnowledgeBase{"bound": f.Config}
	id := submit(t, s, snap)
	r := claim(t, s, "one")
	worker := Worker{Store: s, Lease: 10 * time.Second, ToolHubURL: hub.URL, Token: testToken}
	worker.execute(ctx, r)
	done, e := s.Run(ctx, id)
	if e != nil || done.Status != "completed" {
		t.Fatal("end-to-end bound retrieval failed", done.State.Error, e)
	}
	if _, e = s.Retrieve(ctx, ref, f.Config, ""); e == nil {
		t.Fatal("empty query accepted")
	}
}
func TestEmbeddingRejectsDimensionDrift(t *testing.T) {
	s, _ := testStore(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		jsonResponse(w, 200, map[string]any{"data": []any{map[string]any{"index": 0, "embedding": []int{1, 2, 3}}}})
	}))
	defer server.Close()
	_, e := s.Embed(context.Background(), KnowledgeBase{Embedding: ModelConfig{BaseURL: server.URL, Model: "fixture"}, Dimensions: 2}, []string{"test"}, false)
	if e == nil {
		t.Fatal(errors.New("changed vector semantics accepted"))
	}
}
