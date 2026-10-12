package platform

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/euler-gaozl/agent-os/internal/recordstore"
	"github.com/euler-gaozl/agent-os/internal/serviceclient"
	"github.com/euler-gaozl/agent-os/internal/servicehttp"
	storageapi "github.com/euler-gaozl/agent-os/services/storage"
	"github.com/jackc/pgx/v5"
)

// No artifact tables in Runtime and no execution tables in Storage. Unlike a
// mocked HTTP response this exercises the actual independent service boundary.
func artifactPair(t *testing.T) (*Store, *recordstore.Store) {
	t.Helper()
	runtime, dsn := testStore(t)
	ctx := context.Background()
	schema := "storage_test_" + ID()
	if _, e := runtime.DB.Exec(ctx, "CREATE SCHEMA "+schema); e != nil {
		t.Fatal(e)
	}
	u, e := url.Parse(dsn)
	if e != nil {
		t.Fatal(e)
	}
	q := u.Query()
	q.Set("search_path", schema)
	u.RawQuery = q.Encode()
	retained, e := Open(ctx, u.String())
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() {
		retained.DB.Close()
		if _, e := runtime.DB.Exec(context.Background(), "DROP SCHEMA "+schema+" CASCADE"); e != nil {
			t.Error(e)
		}
	})
	if e = MigrateService(ctx, retained.DB, "storage"); e != nil {
		t.Fatal(e)
	}
	var exists bool
	if e = retained.DB.QueryRow(ctx, "SELECT to_regclass('runs') IS NOT NULL").Scan(&exists); e != nil || exists {
		t.Fatal("storage requires execution tables", e)
	}
	var runtimeSchema string
	if e = runtime.DB.QueryRow(ctx, "SELECT current_schema()").Scan(&runtimeSchema); e != nil || !strings.HasPrefix(runtimeSchema, "test_") {
		t.Fatal("isolated runtime fixture required", e)
	}
	if _, e = runtime.DB.Exec(ctx, "DROP TABLE "+pgx.Identifier{runtimeSchema, "artifact_refs"}.Sanitize()+", "+pgx.Identifier{runtimeSchema, "artifacts"}.Sanitize()+" CASCADE"); e != nil {
		t.Fatal(e)
	}
	store := &recordstore.Store{DB: retained.DB}
	server := httptest.NewServer((&storageapi.Server{Store: store, HTTP: servicehttp.Config{Role: "storage", Peers: map[string]string{"runtime": servicehttp.TokenHash(testToken), "worker": servicehttp.TokenHash(testToken + "worker"), "control": servicehttp.TokenHash(testToken + "control")}}}).Handler())
	t.Cleanup(server.Close)
	runtime.StorageURL = server.URL
	runtime.Remote = &serviceclient.Client{Token: testToken}
	return runtime, store
}

func TestArtifactsCrossIndependentStorageBoundary(t *testing.T) {
	runtime, retained := artifactPair(t)
	ctx := context.Background()
	snap := basicSnapshot("https://example.invalid")
	snap.Agent.Tools = []string{"artifact_read"}
	submit(t, runtime, snap)
	owner := claim(t, runtime, "artifact-owner")
	submit(t, runtime, snap)
	other := claim(t, runtime, "artifact-other")
	body := []byte("库存甲乙：105吨，证据末尾")
	hash, e := runtime.PutArtifact(ctx, body, "text/plain", "run:"+owner.ID)
	if e != nil {
		t.Fatal(e)
	}
	// Reproduce caller recovery after Storage committed and the receipt was lost.
	if again, e := runtime.PutArtifact(ctx, body, "text/plain", "run:"+owner.ID); e != nil || again != hash {
		t.Fatal("retry identity changed", e)
	}
	var count int
	if e = retained.DB.QueryRow(ctx, "SELECT count(*) FROM artifact_refs WHERE hash=$1", hash).Scan(&count); e != nil || count != 1 {
		t.Fatal("upload retry duplicated retention", count, e)
	}
	inv := invocation(other)
	inv.Name = "artifact_read"
	inv.Arguments = JSON(map[string]any{"hash": hash})
	if _, e = runtime.LocalTool(ctx, inv); e == nil {
		t.Fatal("cross-run hash granted access")
	}
	if e = retained.DB.QueryRow(ctx, "SELECT count(*) FROM artifact_refs WHERE root=$1", "run:"+other.ID).Scan(&count); e != nil || count != 0 {
		t.Fatal("denied read adopted artifact", count, e)
	}
	inv = invocation(owner)
	inv.Name = "artifact_read"
	inv.Arguments = JSON(map[string]any{"hash": hash, "offset": 2, "limit": 3})
	result, e := runtime.LocalTool(ctx, inv)
	var page struct {
		Content    string `json:"content"`
		NextOffset int    `json:"next_offset"`
	}
	if e != nil || json.Unmarshal(result, &page) != nil || page.Content != "甲乙：" || page.NextOffset != 5 {
		t.Fatal("Unicode paging through Storage failed", result, e)
	}
	tx, e := runtime.DB.Begin(ctx)
	if e != nil {
		t.Fatal(e)
	}
	defer tx.Rollback(ctx)
	child, e := insertRun(ctx, tx, ID(), "child", snap, &owner.ID, nil)
	if e != nil {
		t.Fatal(e)
	}
	if e = tx.Commit(ctx); e != nil {
		t.Fatal(e)
	}
	childHash, e := runtime.PutArtifact(ctx, []byte("delegated evidence"), "text/plain", "run:"+child)
	if e != nil {
		t.Fatal(e)
	}
	inv.OperationID = ID()
	inv.Arguments = JSON(map[string]any{"hash": childHash})
	if _, e = runtime.LocalTool(ctx, inv); e != nil {
		t.Fatal("parent cannot read child evidence", e)
	}
	if e = retained.DB.QueryRow(ctx, "SELECT count(*) FROM artifact_refs WHERE root=$1 AND hash=$2", "run:"+owner.ID, childHash).Scan(&count); e != nil || count != 1 {
		t.Fatal("parent did not retain referenced evidence", e)
	}
}

func TestStorageHTTPValidatesRolePayloadAndBounds(t *testing.T) {
	runtime, retained := artifactPair(t)
	ctx := context.Background()
	root := "run:" + ID()
	large := []byte(strings.Repeat("a", 3<<20)) // binary upload must exceed JSON's 2 MiB limit safely.
	worker := serviceclient.Client{Token: testToken + "worker"}
	hash, e := worker.PutArtifact(ctx, runtime.StorageURL, large, "text/plain", root)
	if e != nil {
		t.Fatal("bounded binary upload failed", e)
	}
	page := recordstore.ArtifactPageRequest{Hash: hash, Roots: []string{root}, AdoptRoot: root, Limit: 5}
	var out any
	if e = worker.Request(ctx, "POST", runtime.StorageURL+"/v1/artifacts/page", page, &out); e == nil {
		t.Fatal("worker bypassed Runtime read scope")
	}
	control := serviceclient.Client{Token: testToken + "control"}
	if _, e = control.PutArtifact(ctx, runtime.StorageURL, []byte("x"), "text/plain", root); e == nil {
		t.Fatal("control fabricated run retention root")
	}
	for _, bad := range []recordstore.ArtifactPageRequest{
		{Hash: hash, Roots: []string{root}, AdoptRoot: "run:" + ID()},
		{Hash: hash, Roots: []string{root}, AdoptRoot: root, Offset: -1},
		{Hash: hash, Roots: []string{root}, AdoptRoot: root, Limit: 1201},
		{Hash: hash, Roots: []string{root}, AdoptRoot: root, Offset: len(large) + 1},
	} {
		if e = runtime.Remote.Request(ctx, "POST", runtime.StorageURL+"/v1/artifacts/page", bad, &out); e == nil {
			t.Fatal("invalid page accepted", bad)
		}
	}
	for _, tc := range []struct {
		name, hash, body string
		status           int
	}{
		{"hash mismatch", hash, "wrong content", 400},
		{"size limit", Hash([]byte("large")), strings.Repeat("x", (4<<20)+1), 413},
	} {
		t.Run(tc.name, func(t *testing.T) {
			req, _ := http.NewRequest("PUT", runtime.StorageURL+"/v1/artifacts/"+tc.hash, strings.NewReader(tc.body))
			req.Header.Set("Authorization", "Bearer "+testToken)
			req.Header.Set("X-Artifact-Root", root)
			req.Header.Set("X-Artifact-Media-Type", "text/plain")
			resp, e := http.DefaultClient.Do(req)
			if e != nil {
				t.Fatal(e)
			}
			resp.Body.Close()
			if resp.StatusCode != tc.status {
				t.Fatal("unexpected status", resp.StatusCode)
			}
		})
	}
	var count int
	if e = retained.DB.QueryRow(ctx, "SELECT count(*) FROM artifacts").Scan(&count); e != nil || count != 1 {
		t.Fatal("invalid upload left stored bytes", count, e)
	}
}
