package platform

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"unicode/utf8"

	"github.com/euler-gaozl/agent-os/internal/recordstore"
	"github.com/euler-gaozl/agent-os/internal/serviceclient"
	"github.com/euler-gaozl/agent-os/internal/servicehttp"
	storageapi "github.com/euler-gaozl/agent-os/services/storage"
)

func stageArchiveFixture(t *testing.T, s *Store, r Run, seq, start int, body []byte) {
	t.Helper()
	ctx := context.Background()
	tx, e := s.DB.Begin(ctx)
	if e != nil {
		t.Fatal(e)
	}
	defer tx.Rollback(ctx)
	if e = lockRun(ctx, tx, r.ID, r.Owner, r.Fence, false); e != nil {
		t.Fatal(e)
	}
	if _, e = tx.Exec(ctx, "INSERT INTO harness_exchanges(run_id,seq,method,input_hash,request,rule_revision) VALUES($1,$2,'model','fixture','{}',1)", r.ID, seq); e != nil {
		t.Fatal(e)
	}
	var events []json.RawMessage
	if e = json.Unmarshal(body, &events); e != nil {
		t.Fatal(e)
	}
	if e = stageHarnessArchive(ctx, tx, r, harnessFrame{ID: seq, Events: body, EventStart: start, EventEnd: start + len(events)}); e != nil {
		t.Fatal(e)
	}
	if e = tx.Commit(ctx); e != nil {
		t.Fatal(e)
	}
}

func readArchiveFixture(t *testing.T, s *Store, hash string) ([]byte, HarnessArchive) {
	t.Helper()
	ctx := context.Background()
	raw, _, e := s.Artifact(ctx, hash)
	if e != nil {
		t.Fatal(e)
	}
	var a HarnessArchive
	if e = json.Unmarshal(raw, &a); e != nil {
		t.Fatal(e)
	}
	if a.Version != 1 || len(a.Parts) > 18 {
		t.Fatal("invalid manifest", a.Version, len(a.Parts))
	}
	body := []byte{}
	for _, part := range a.Parts {
		b, _, err := s.Artifact(ctx, part.Hash)
		if err != nil || len(b) != part.Bytes || part.Offset != len(body) || len(b) > archiveSegmentBytes || !utf8.Valid(b) || Hash(b) != part.Hash {
			t.Fatal("invalid retained segment", err)
		}
		body = append(body, b...)
	}
	if len(body) != a.Bytes || Hash(body) != a.SHA256 || !json.Valid(body) {
		t.Fatal("manifest did not reconstruct exact batch")
	}
	return body, a
}

func TestArchiveOutboxRetainsFirstBatchAfterLostStorageReceipt(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	submit(t, s, basicSnapshot("https://fixture.invalid"))
	r := claim(t, s, "original")
	body := JSON([]any{map[string]any{"type": "fixture", "text": strings.Repeat("跨分段中文原文", 100000)}})
	stageArchiveFixture(t, s, r, 1, 0, body)
	backing := (&storageapi.Server{Store: &recordstore.Store{DB: s.DB}, HTTP: servicehttp.Config{Role: "storage", Peers: map[string]string{"runtime": servicehttp.TokenHash(testToken)}}}).Handler()
	var lost atomic.Bool
	lost.Store(true)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		rw := httptest.NewRecorder()
		backing.ServeHTTP(rw, req)
		if req.Header.Get("X-Artifact-Media-Type") == "application/vnd.agentos.event-manifest+json" && lost.CompareAndSwap(true, false) {
			w.WriteHeader(503)
			return
		}
		for k, v := range rw.Header() {
			w.Header()[k] = v
		}
		w.WriteHeader(rw.Code)
		_, _ = w.Write(rw.Body.Bytes())
	}))
	defer server.Close()
	s.StorageURL = server.URL
	s.Remote = &serviceclient.Client{Token: testToken}
	if _, e := s.commitHarnessArchive(ctx, r, 1); e == nil {
		t.Fatal("lost acknowledgement accepted")
	}
	var pending []byte
	var hash string
	if e := s.DB.QueryRow(ctx, "SELECT batch,manifest_hash FROM harness_archives WHERE run_id=$1", r.ID).Scan(&pending, &hash); e != nil || Hash(pending) != Hash(body) || hash != "" {
		t.Fatal("first staged batch not retained", e)
	}
	var countBefore int
	if e := s.DB.QueryRow(ctx, "SELECT count(*) FROM artifacts").Scan(&countBefore); e != nil {
		t.Fatal(e)
	}
	if _, e := s.DB.Exec(ctx, "UPDATE runs SET lease_until=now()-interval '1 second' WHERE id=$1", r.ID); e != nil {
		t.Fatal(e)
	}
	current := claim(t, s, "replacement")
	if _, e := s.commitHarnessArchive(ctx, r, 1); !errors.Is(e, ErrFence) {
		t.Fatal("old uploader acknowledged archive", e)
	}
	hash, e := s.commitHarnessArchive(ctx, current, 1)
	if e != nil {
		t.Fatal(e)
	}
	retained, a := readArchiveFixture(t, s, hash)
	if string(retained) != string(body) || a.SourceOwner != r.Owner || a.SourceFence != r.Fence || len(a.Parts) < 2 {
		t.Fatal("recovery replaced original batch/provenance")
	}
	var countAfter int
	if e = s.DB.QueryRow(ctx, "SELECT count(*) FROM artifacts").Scan(&countAfter); e != nil || countBefore != countAfter {
		t.Fatal("retransmission duplicated artifacts", e, countBefore, countAfter)
	}
	if e = s.DB.QueryRow(ctx, "SELECT batch FROM harness_archives WHERE run_id=$1", r.ID).Scan(&pending); e != nil || pending != nil {
		t.Fatal("acknowledged staging copy not retired", e)
	}
	// A rebuilt native session may have a different local index. The accepted
	// directory remains contiguous while retaining each attempt's real offsets.
	stageArchiveFixture(t, s, current, 2, 37, JSON([]any{map[string]string{"type": "after-replay"}}))
	hash2, e := s.commitHarnessArchive(ctx, current, 2)
	if e != nil {
		t.Fatal(e)
	}
	_, a2 := readArchiveFixture(t, s, hash2)
	if a2.Previous != hash || a2.EventStart != a.EventEnd || a2.SourceStart != 37 {
		t.Fatal("cross-attempt archive chain/provenance lost")
	}
}

func TestFutureEngineCannotBeClaimedByCurrentWorker(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	future := submit(t, s, basicSnapshot("https://fixture.invalid"))
	if _, e := s.DB.Exec(ctx, "UPDATE runs SET engine='future-unsupported' WHERE id=$1", future); e != nil {
		t.Fatal(e)
	}
	current := submit(t, s, basicSnapshot("https://fixture.invalid"))
	r := claim(t, s, "supported-only")
	if r.ID != current {
		t.Fatal("unsupported engine was claimed")
	}
	old, e := s.Run(ctx, future)
	if e != nil || old.Status != "queued" || old.Fence != 0 {
		t.Fatal("unsupported run was mutated", e)
	}
}

func TestArchiveCancellationKeepsStagedBytesAndCannotAcknowledge(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	submit(t, s, basicSnapshot("https://fixture.invalid"))
	r := claim(t, s, "cancel-during-upload")
	body := JSON([]any{map[string]string{"type": "before-cancel", "text": "保留原始资料"}})
	stageArchiveFixture(t, s, r, 1, 0, body)
	backing := (&storageapi.Server{Store: &recordstore.Store{DB: s.DB}, HTTP: servicehttp.Config{Role: "storage", Peers: map[string]string{"runtime": servicehttp.TokenHash(testToken)}}}).Handler()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		backing.ServeHTTP(w, req)
		if _, e := s.DB.Exec(ctx, "UPDATE runs SET cancel_requested=true WHERE id=$1", r.ID); e != nil {
			t.Error(e)
		}
	}))
	defer server.Close()
	s.StorageURL, s.Remote = server.URL, &serviceclient.Client{Token: testToken}
	if _, e := s.commitHarnessArchive(ctx, r, 1); !errors.Is(e, ErrFence) {
		t.Fatal("cancelled upload acknowledged", e)
	}
	var raw []byte
	var hash string
	if e := s.DB.QueryRow(ctx, "SELECT batch,manifest_hash FROM harness_archives WHERE run_id=$1", r.ID).Scan(&raw, &hash); e != nil || string(raw) != string(body) || hash != "" {
		t.Fatal("cancelled upload lost staged evidence", e)
	}
}

func TestDSHFailureArchivesFinalEventsBeforeReportingError(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	submit(t, s, basicSnapshot("https://fixture.invalid"))
	r := claim(t, s, "failure-retention")
	body := JSON([]any{map[string]string{"type": "turn/end", "reason": "fixture-failure"}})
	w := Worker{Store: s}
	_, _, e := w.harnessExchange(ctx, &r, harnessFrame{ID: 1, Method: "failed", Params: JSON(map[string]string{"error": "fixture-failure"}), Events: body, EventEnd: 1})
	if e == nil || !strings.Contains(e.Error(), "fixture-failure") || r.State.HarnessArtifact == "" {
		t.Fatal("failure discarded final evidence", e)
	}
	retained, _ := readArchiveFixture(t, s, r.State.HarnessArtifact)
	if string(retained) != string(body) {
		t.Fatal("failure evidence changed")
	}
}
