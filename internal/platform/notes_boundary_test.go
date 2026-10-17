package platform

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/euler-gaozl/agent-os/internal/serviceclient"
	"github.com/euler-gaozl/agent-os/internal/servicehost"
	"github.com/euler-gaozl/agent-os/internal/servicehttp"
	"github.com/jackc/pgx/v5"
)

// Only the selected owner's migration runs. No placeholder or shared tables
// can conceal a cross-domain dependency, including in schema readiness checks.
func isolatedDomainDatabase(t *testing.T, domain string) *Store {
	t.Helper()
	base := os.Getenv("TEST_DATABASE_URL")
	if base == "" {
		t.Skip("TEST_DATABASE_URL absent; independent PostgreSQL databases not tested")
	}
	entry, e := filepath.Abs("../../harness/runner.mjs")
	if e != nil {
		t.Fatal(e)
	}
	t.Setenv("DSH_RUNNER", entry)
	ctx := context.Background()
	admin, e := Open(ctx, base)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(admin.DB.Close)
	name := "agentos_boundary_" + ID()
	if _, e = admin.DB.Exec(ctx, "CREATE DATABASE "+pgx.Identifier{name}.Sanitize()); e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() {
		if _, e := admin.DB.Exec(context.Background(), "DROP DATABASE "+pgx.Identifier{name}.Sanitize()+" WITH (FORCE)"); e != nil {
			t.Error(e)
		}
	})
	u, e := url.Parse(base)
	if e != nil {
		t.Fatal(e)
	}
	u.Path = "/" + name
	q := u.Query()
	q.Set("search_path", "public")
	u.RawQuery = q.Encode()
	s, e := Open(ctx, u.String())
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(s.DB.Close)
	if e = MigrateService(ctx, s.DB, domain); e != nil {
		t.Fatal(e)
	}
	if e = servicehost.SchemaReadiness(domain, s.DB)(ctx); e != nil {
		t.Fatal("owner-only readiness", e)
	}
	missing := []string{"artifacts", "artifact_refs", "resources", "secrets"}
	if domain == "storage" {
		missing = []string{"documents", "runs", "calls", "resources", "secrets"}
	}
	for _, table := range missing {
		var absent bool
		if e = s.DB.QueryRow(ctx, "SELECT to_regclass($1) IS NULL", table).Scan(&absent); e != nil || !absent {
			t.Fatalf("%s unexpectedly depends on %s: %v", domain, table, e)
		}
	}
	return s
}

func TestRuntimeNotesAtomicRecoveryWithoutStorage(t *testing.T) {
	s := isolatedDomainDatabase(t, "runtime")
	ctx := context.Background()
	s.StorageURL = "http://127.0.0.1:1" // deliberately unavailable; notes never need it.
	s.Remote = &serviceclient.Client{Token: testToken}
	submit(t, s, basicSnapshot("https://example.invalid"))
	run := claim(t, s, "before-crash")
	inv := invocation(run)
	// Force failure after the document and call inserts, before COMMIT.
	_, e := s.DB.Exec(ctx, `CREATE FUNCTION reject_note_event() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN IF NEW.kind='tool_completed' THEN RAISE EXCEPTION 'injected before commit'; END IF; RETURN NEW; END $$;
CREATE TRIGGER reject_note_event BEFORE INSERT ON events FOR EACH ROW EXECUTE FUNCTION reject_note_event()`)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.LocalTool(ctx, inv); e == nil {
		t.Fatal("commit failure missing")
	}
	assertCounts := func(want int) {
		t.Helper()
		var docs, calls, events int
		e := s.DB.QueryRow(ctx, "SELECT (SELECT count(*) FROM documents),(SELECT count(*) FROM calls),(SELECT count(*) FROM events WHERE kind='tool_completed')").Scan(&docs, &calls, &events)
		if e != nil || docs != want || calls != want || events != want {
			t.Fatal("non-atomic note/receipt/event", docs, calls, events, e)
		}
	}
	assertCounts(0)
	if _, e = s.DB.Exec(ctx, "DROP TRIGGER reject_note_event ON events"); e != nil {
		t.Fatal(e)
	}
	first, e := s.LocalTool(ctx, inv)
	if e != nil {
		t.Fatal(e)
	}
	// The reply is lost. A later owner replays the same logical operation.
	if _, e = s.DB.Exec(ctx, "UPDATE runs SET lease_until=now()-interval '1 second' WHERE id=$1", run.ID); e != nil {
		t.Fatal(e)
	}
	replacement := claim(t, s, "after-crash")
	if _, e = s.LocalTool(ctx, inv); e == nil {
		t.Fatal("stale owner committed")
	}
	inv.Owner, inv.Fence = replacement.Owner, replacement.Fence
	again, e := s.LocalTool(ctx, inv)
	var before, after Document
	if e != nil || json.Unmarshal(first, &before) != nil || json.Unmarshal(again, &after) != nil || before.ID == "" || before.ID != after.ID || after.Scope != "test" {
		t.Fatal("durable note replay changed", e)
	}
	assertCounts(1)
	inv.Arguments = JSON(map[string]any{"kind": "fact", "title": "changed", "content": "wrong", "source": "test://changed"})
	if _, e = s.LocalTool(ctx, inv); e == nil {
		t.Fatal("same operation changed input")
	}
	assertCounts(1)
	// This is persistent Agent memory; finishing/cancelling a task is not GC.
	if e = s.Cancel(ctx, run.ID); e != nil {
		t.Fatal(e)
	}
	inv.OperationID += "/after-cancel"
	if _, e = s.LocalTool(ctx, inv); e == nil {
		t.Fatal("cancelled task wrote a note")
	}
	assertCounts(1)
	read, e := s.Search(ctx, "fixture value", "fact")
	if e != nil || len(read) != 1 || read[0].ID != before.ID {
		t.Fatal("persistent note disappeared", e)
	}
}

func TestRuntimeNotesManagementAuthorizationAndRevisions(t *testing.T) {
	s := isolatedDomainDatabase(t, "runtime")
	peers := map[string]string{}
	for _, role := range []string{"control", "futures", "storage", "worker", "toolhub", "knowledge"} {
		peers[role] = servicehttp.TokenHash(testToken + role)
	}
	h := (&Server{Store: s}).RuntimeHandler(servicehttp.Config{Role: "runtime", Peers: peers})
	req := func(role, method, path, body string) *httptest.ResponseRecorder {
		t.Helper()
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		r.Header.Set("Authorization", "Bearer "+testToken+role)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	body := `{"kind":"memory","title":"reviewed preference","content":"keep original evidence","source":"test://admin","scope":"agent-a","metadata":{"reviewed":true},"valid_until":"2099-01-01T00:00:00Z"}`
	w := req("control", "POST", "/v1/documents", body)
	var original Document
	if w.Code != 201 || json.Unmarshal(w.Body.Bytes(), &original) != nil {
		t.Fatal(w.Code, w.Body.String())
	}
	for _, role := range []string{"futures", "storage", "worker", "toolhub", "knowledge"} {
		for _, call := range []struct{ method, path string }{{"GET", "/v1/documents"}, {"GET", "/v1/documents/" + original.ID}, {"POST", "/v1/documents"}} {
			if w := req(role, call.method, call.path, body); w.Code != 403 {
				t.Fatal("unauthorized note access", role, call, w.Code)
			}
		}
	}
	for _, method := range []string{"PUT", "PATCH", "DELETE"} {
		if w := req("control", method, "/v1/documents", body); w.Code != 403 {
			t.Fatal("unimplemented mutation authorized", w.Code)
		}
	}
	revision := original
	revision.ID = ""
	revision.Supersedes = &original.ID
	revision.Content = "keep immutable original evidence"
	w = req("control", "POST", "/v1/documents", string(JSON(revision)))
	if w.Code != 201 {
		t.Fatal(w.Code, w.Body.String())
	}
	if e := MigrateService(context.Background(), s.DB, "runtime"); e != nil {
		t.Fatal(e)
	}
	w = req("control", "GET", "/v1/documents/"+original.ID, "")
	var preserved Document
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &preserved) != nil || preserved.Content != original.Content || preserved.Scope != original.Scope || preserved.ValidUntil == nil || preserved.Metadata["reviewed"] != true {
		t.Fatal("migration/revision rewrote note", w.Code, w.Body.String())
	}
	w = req("control", "GET", "/v1/documents?q=immutable&kind=memory", "")
	var found []Document
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &found) != nil || len(found) != 1 || found[0].Supersedes == nil || *found[0].Supersedes != original.ID {
		t.Fatal("revision listing lost provenance", w.Code, w.Body.String())
	}
	// The historical role-selectable entry point remains a supported recovery
	// path; it must expose the same read route after the ownership transfer.
	legacy := (&Server{Store: s, Role: "runtime", Token: testToken}).Handler()
	r := httptest.NewRequest("GET", "/v1/documents/"+original.ID, nil)
	r.Header.Set("Authorization", "Bearer "+testToken)
	w = httptest.NewRecorder()
	legacy.ServeHTTP(w, r)
	if w.Code != 200 || !strings.Contains(w.Body.String(), original.ID) {
		t.Fatal("legacy entry point lost note API", w.Code)
	}
}
