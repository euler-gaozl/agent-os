package knowledge

import (
	"context"
	"encoding/json"
	. "github.com/euler-gaozl/agent-os/internal/contracts"
	"github.com/jackc/pgx/v5/pgxpool"
	"net/url"
	"os"
	"strings"
	"testing"
)

type fixtureResources struct{}

func (fixtureResources) Resource(ctx context.Context, kind string, ref Ref, dst any) error {
	return json.Unmarshal(JSON(KnowledgeBase{Name: "Fixture", Engine: "local", ChunkSize: 200}), dst)
}
func knowledgeStore(t *testing.T) *Store {
	t.Helper()
	base := os.Getenv("TEST_DATABASE_URL")
	if base == "" {
		t.Skip("PostgreSQL required")
	}
	ctx := context.Background()
	admin, e := pgxpool.New(ctx, base)
	if e != nil {
		t.Fatal(e)
	}
	schema := "kb_test_" + ID()
	if _, e = admin.Exec(ctx, "CREATE SCHEMA "+schema); e != nil {
		t.Fatal(e)
	}
	u, _ := url.Parse(base)
	q := u.Query()
	q.Set("search_path", schema)
	u.RawQuery = q.Encode()
	p, e := pgxpool.New(ctx, u.String())
	if e != nil {
		t.Fatal(e)
	}
	if e = Migrate(ctx, p); e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() {
		p.Close()
		_, e := admin.Exec(context.Background(), "DROP SCHEMA "+schema+" CASCADE")
		if e != nil {
			t.Error(e)
		}
		admin.Close()
	})
	return &Store{DB: p, ResourceReader: fixtureResources{}}
}
func TestIncrementalBackfillAndScopedOriginalDocument(t *testing.T) {
	s := knowledgeStore(t)
	ctx := context.Background()
	ref := Ref{ID: "test", Revision: 1}
	body := []byte(strings.Repeat("甲醇库存 controlled source. ", 1400))
	file, e := s.UploadKnowledge(ctx, ref, "source.txt", "fixture://original", body)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.DB.Exec(ctx, "UPDATE knowledge_chunks SET search_vector=NULL"); e != nil {
		t.Fatal(e)
	}
	first, e := s.IndexLocalBatch(ctx)
	if e != nil || first != 128 {
		t.Fatal(first, e)
	}
	second, e := s.IndexLocalBatch(ctx)
	if e != nil || second == 0 {
		t.Fatal(second, e)
	}
	for {
		n, e := s.IndexLocalBatch(ctx)
		if e != nil {
			t.Fatal(e)
		}
		if n == 0 {
			break
		}
	}
	hits, e := s.Retrieve(ctx, ref, KnowledgeBase{Engine: "local"}, "甲醇库存")
	if e != nil || len(hits.Hits) == 0 || len(hits.Hits) > 8 {
		t.Fatal(hits, e)
	}
	wrong, e := s.Retrieve(ctx, Ref{ID: "test", Revision: 2}, KnowledgeBase{Engine: "local"}, "甲醇库存")
	if e != nil || len(wrong.Hits) != 0 {
		t.Fatal(wrong, e)
	}
	run := Run{Snapshot: Snapshot{Agent: Agent{Knowledge: []Ref{ref}}}}
	out, e := s.ReadDocument(ctx, run, file.DocumentID, 0, 100)
	if e != nil || !strings.Contains(string(JSON(out)), "fixture://original") {
		t.Fatal(out, e)
	}
	run.Snapshot.Agent.Knowledge[0].Revision = 2
	if _, e = s.ReadDocument(ctx, run, file.DocumentID, 0, 100); e == nil {
		t.Fatal("read crossed knowledge revision")
	}
	if _, e = s.Retrieve(ctx, ref, KnowledgeBase{Engine: "local"}, "甲"); e == nil {
		t.Fatal("unindexable query accepted")
	}
}
