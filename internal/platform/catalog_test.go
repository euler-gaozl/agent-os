package platform

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/euler-gaozl/agent-os/internal/catalog"
	"strings"
	"testing"
)

func TestCatalogPagesDoNotLoadOrOverwriteFullDefinitions(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	// Full prompts total >50 MB. Each page must remain independent of that size.
	prompt := strings.Repeat("长期资料", 18000) + "KEEP-END-479"
	spec := JSON(map[string]any{"name": "Latest index name", "prompt": prompt, "model": map[string]string{"model": "fixture"}, "skills": []Ref{{ID: "pinned", Revision: 7}}, "constraints": []string{"keep this rule"}})
	_, e := s.DB.Exec(ctx, `INSERT INTO resources(kind,id,revision,spec) SELECT 'agent','page-'||lpad(i::text,3,'0'),r,$1::jsonb FROM generate_series(1,210)i CROSS JOIN generate_series(1,2)r`, spec)
	if e != nil {
		t.Fatal(e)
	}
	after := ""
	seen := map[string]bool{}
	pages := 0
	for {
		p, e := s.Catalog(ctx, catalog.Query{Kind: "agent", After: after, Limit: 100})
		if e != nil {
			t.Fatal(e)
		}
		pages++
		if len(JSON(p)) > 120000 {
			t.Fatal("full definitions leaked into summary page")
		}
		for _, r := range p.Items {
			if seen[r.ID] || r.Revision != 2 || !r.Summary {
				t.Fatalf("invalid page item %s", r.ID)
			}
			seen[r.ID] = true
			if strings.Contains(string(r.Spec), "KEEP-END-479") || strings.Contains(string(r.Spec), "keep this rule") {
				t.Fatal("private definition body in index")
			}
		}
		if p.Next == "" {
			break
		}
		after = p.Next
		if pages > 4 {
			t.Fatal("cursor did not advance")
		}
	}
	if len(seen) != 210 || pages != 3 {
		t.Fatalf("coverage: %d items/%d pages", len(seen), pages)
	}
	filtered, e := s.Catalog(ctx, catalog.Query{Kind: "agent", Search: "page-209", Limit: 3})
	if e != nil || len(filtered.Items) != 1 {
		t.Fatalf("server search failed: %v", e)
	}
	var full json.RawMessage
	if e = s.Resource(ctx, "agent", Ref{ID: "page-209", Revision: 2}, &full); e != nil {
		t.Fatal(e)
	}
	var original, actual map[string]any
	_ = json.Unmarshal(spec, &original)
	_ = json.Unmarshal(full, &actual)
	if string(JSON(original)) != string(JSON(actual)) {
		t.Fatal("full version lost fields")
	}
	legacy, e := s.Resources(ctx)
	if e != nil {
		t.Fatal(e)
	}
	if len(legacy) == 0 || len(legacy) >= 100 || len(JSON(legacy)) > 2<<20 {
		t.Fatal("legacy full list not byte bounded")
	}
	page2, e := s.Resources(ctx, catalog.Key(legacy[len(legacy)-1]))
	if e != nil || len(page2) == 0 || page2[0].ID != fmt.Sprintf("page-%03d", len(legacy)+1) {
		t.Fatalf("legacy page skipped content: %v", e)
	}
}
