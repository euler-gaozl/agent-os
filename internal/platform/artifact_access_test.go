package platform

import (
	"context"
	"testing"
)

func TestArtifactHashDoesNotGrantCrossRunAccess(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	snap := basicSnapshot("https://example.invalid")
	snap.Agent.Tools = []string{"artifact_read"}
	submit(t, s, snap)
	owner := claim(t, s, "artifact-owner")
	submit(t, s, snap)
	other := claim(t, s, "artifact-other")
	hash, e := s.PutArtifact(ctx, []byte("private-run-evidence"), "text/plain", "run:"+owner.ID)
	if e != nil {
		t.Fatal(e)
	}
	inv := invocation(other)
	inv.Name = "artifact_read"
	inv.Arguments = JSON(map[string]any{"hash": hash})
	if _, e = s.LocalTool(ctx, inv); e == nil {
		t.Fatal("content hash incorrectly treated as authorization")
	}
	var count int
	if e = s.DB.QueryRow(ctx, "SELECT count(*) FROM artifact_refs WHERE root=$1 AND hash=$2", "run:"+other.ID, hash).Scan(&count); e != nil || count != 0 {
		t.Fatal("denied read acquired a reference", e)
	}
	inv = invocation(owner)
	inv.Name = "artifact_read"
	inv.Arguments = JSON(map[string]any{"hash": hash})
	if _, e = s.LocalTool(ctx, inv); e != nil {
		t.Fatal("owner lost access", e)
	}
	tx, e := s.DB.Begin(ctx)
	if e != nil {
		t.Fatal(e)
	}
	childID, e := insertRun(ctx, tx, ID(), "child", snap, &owner.ID, nil)
	if e != nil {
		t.Fatal(e)
	}
	if e = tx.Commit(ctx); e != nil {
		t.Fatal(e)
	}
	childHash, e := s.PutArtifact(ctx, []byte("child-evidence"), "text/plain", "run:"+childID)
	if e != nil {
		t.Fatal(e)
	}
	inv.OperationID = ID()
	inv.Arguments = JSON(map[string]any{"hash": childHash})
	if _, e = s.LocalTool(ctx, inv); e != nil {
		t.Fatal("parent cannot read delegated child evidence", e)
	}
}
