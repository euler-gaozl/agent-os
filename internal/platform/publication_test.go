package platform

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestLegacyActionMigrationPreservesVersionsAndIsIdempotent(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	a := basicSnapshot("http://127.0.0.1").Agent
	a.Knowledge = []Ref{{"kb", 2}}
	a.Constraints = []string{"keep sources"}
	resource, e := s.PutResource(ctx, "agent", "source", JSON(a))
	if e != nil {
		t.Fatal(e)
	}
	old := BusinessAction{Name: "Inventory", Description: "Facts only", Agent: Ref{resource.ID, resource.Revision}, Instruction: "Check warehouse receipts", Constraints: []string{"no prediction"}}
	if _, e = s.PutResource(ctx, "action", "inventory", JSON(old)); e != nil {
		t.Fatal(e)
	}
	if _, e = s.DB.Exec(ctx, "DELETE FROM schema_versions WHERE version=4"); e != nil {
		t.Fatal(e)
	}
	for i := 0; i < 2; i++ {
		if e = s.Migrate(ctx); e != nil {
			t.Fatal(e)
		}
	}
	var published Agent
	if e = s.Resource(ctx, "agent", Ref{"published-inventory", 1}, &published); e != nil {
		t.Fatal(e)
	}
	if !published.Publication.Enabled || published.Knowledge[0].Revision != 2 || len(published.Constraints) != 2 || published.Prompt != a.Prompt+"\n\n"+old.Instruction {
		t.Fatal("migration lost bindings or instructions")
	}
	var count int
	_ = s.DB.QueryRow(ctx, "SELECT count(*) FROM resources WHERE kind='action'").Scan(&count)
	if count != 1 {
		t.Fatal("historical action deleted")
	}
	_ = s.DB.QueryRow(ctx, "SELECT count(*) FROM resources WHERE kind='agent' AND id='published-inventory'").Scan(&count)
	if count != 1 {
		t.Fatal("migration repeated")
	}
}

func TestUnpublishedAndStaleAgentsCannotStartBusinessTasks(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	a := basicSnapshot("http://127.0.0.1").Agent
	a.Publication = Publication{true, "futures", "Inventory", "Facts"}
	_, e := s.PutResource(ctx, "agent", "published", JSON(a))
	if e != nil {
		t.Fatal(e)
	}
	a.Publication.Enabled = false
	if _, e = s.PutResource(ctx, "agent", "published", JSON(a)); e != nil {
		t.Fatal(e)
	}
	server := httptest.NewServer((&Server{Store: s, Role: "futures", Token: testToken, AdminToken: testToken}).Handler())
	defer server.Close()
	for _, version := range []int{1, 2} {
		req, _ := http.NewRequest("POST", server.URL+"/api/tasks", bytes.NewReader(JSON(map[string]any{"agent": Ref{"published", version}, "commodity": "fixture"})))
		req.Header.Set("Authorization", "Bearer "+testToken)
		req.Header.Set("Idempotency-Key", ID())
		resp, e := http.DefaultClient.Do(req)
		if e != nil {
			t.Fatal(e)
		}
		resp.Body.Close()
		if resp.StatusCode != 400 {
			t.Fatalf("unpublished revision accepted %d", resp.StatusCode)
		}
	}
	req, _ := http.NewRequest("GET", server.URL+"/api/agents", nil)
	req.Header.Set("Authorization", "Bearer "+testToken)
	resp, e := http.DefaultClient.Do(req)
	if e != nil {
		t.Fatal(e)
	}
	defer resp.Body.Close()
	var result []any
	if e = json.NewDecoder(resp.Body).Decode(&result); e != nil || len(result) != 0 {
		t.Fatal("withdrawn agent remains in catalog", e)
	}
}
