package platform

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/euler-gaozl/agent-os/internal/serviceclient"
	"github.com/euler-gaozl/agent-os/internal/servicehttp"
	"github.com/jackc/pgx/v5"
)

func telemetryPair(t *testing.T) (*Store, *Store) {
	t.Helper()
	runtime, dsn := testStore(t)
	ctx := context.Background()
	schema := "telemetry_test_" + ID()
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
	inbox, e := Open(ctx, u.String())
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() {
		inbox.DB.Close()
		if _, e := runtime.DB.Exec(context.Background(), "DROP SCHEMA "+schema+" CASCADE"); e != nil {
			t.Error(e)
		}
	})
	if e = MigrateService(ctx, inbox.DB, "telemetry"); e != nil {
		t.Fatal(e)
	}
	var exists bool
	if e = inbox.DB.QueryRow(ctx, "SELECT to_regclass('events') IS NOT NULL").Scan(&exists); e != nil || exists {
		t.Fatal("telemetry store requires execution tables", e)
	}
	server := &Server{Store: runtime}
	httpServer := httptest.NewServer(servicehttp.New(servicehttp.Config{Role: "runtime", Peers: map[string]string{"telemetry": servicehttp.TokenHash(testToken)}}, nil, server.runtimeRoutes))
	t.Cleanup(httpServer.Close)
	inbox.Remote = &serviceclient.Client{RuntimeURL: httpServer.URL, Token: testToken}
	return runtime, inbox
}

func TestTelemetryInboxSurvivesLostAcknowledgementAndFencesOldDelivery(t *testing.T) {
	runtime, inbox := telemetryPair(t)
	ctx := context.Background()
	submit(t, runtime, basicSnapshot("http://127.0.0.1"))
	owner := ID()
	batch, e := runtime.claimTelemetry(ctx, owner)
	if e != nil || len(batch) != 1 {
		t.Fatal(batch, e)
	}
	if e = inbox.saveTelemetryInbox(ctx, batch); e != nil {
		t.Fatal(e)
	}
	// Crash here: Runtime never receives acknowledgement, but the inbox is durable.
	next, e := runtime.claimTelemetry(ctx, ID())
	if e != nil || len(next) != 0 {
		t.Fatal("active lease duplicated", e)
	}
	if _, e = runtime.DB.Exec(ctx, "UPDATE events SET telemetry_until=now()-interval '1 second'"); e != nil {
		t.Fatal(e)
	}
	newOwner := ID()
	retry, e := runtime.claimTelemetry(ctx, newOwner)
	if e != nil || len(retry) != 1 || retry[0].Fence <= batch[0].Fence {
		t.Fatal("expired delivery not fenced", e)
	}
	if e = runtime.acknowledgeTelemetry(ctx, owner, []telemetryReceipt{{Sequence: batch[0].Sequence, Fence: batch[0].Fence}}); !errors.Is(e, ErrFence) {
		t.Fatal("stale receipt accepted", e)
	}
	if e = inbox.saveTelemetryInbox(ctx, retry); e != nil {
		t.Fatal(e)
	}
	bad := append([]telemetryDelivery{}, retry...)
	bad[0].Kind = "changed"
	if e = inbox.saveTelemetryInbox(ctx, bad); e == nil {
		t.Fatal("same sequence changed identity")
	}
	receipts := []telemetryReceipt{{Sequence: retry[0].Sequence, Fence: retry[0].Fence}}
	if e = runtime.acknowledgeTelemetry(ctx, newOwner, receipts); e != nil {
		t.Fatal(e)
	}
	if e = runtime.acknowledgeTelemetry(ctx, newOwner, receipts); e != nil {
		t.Fatal("acknowledgement is not idempotent", e)
	}
	var count int
	if e = inbox.DB.QueryRow(ctx, "SELECT count(*) FROM telemetry_inbox").Scan(&count); e != nil || count != 1 {
		t.Fatal("duplicate inbox event", count, e)
	}

	t.Setenv("LANGFUSE_PUBLIC_KEY", "fixture-public")
	t.Setenv("LANGFUSE_SECRET_KEY", "fixture-secret")
	var received atomic.Int32
	collector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { received.Add(1); _, _ = w.Write([]byte(`{}`)) }))
	defer collector.Close()
	var wg sync.WaitGroup
	errs := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); errs <- inbox.exportOne(ctx, collector.URL) }()
	}
	wg.Wait()
	close(errs)
	for e := range errs {
		if e != nil && !errors.Is(e, pgx.ErrNoRows) {
			t.Fatal(e)
		}
	}
	if received.Load() != 1 {
		t.Fatal("concurrent exporters sent duplicate committed span")
	}
	if e = inbox.exportOne(ctx, collector.URL); !errors.Is(e, pgx.ErrNoRows) {
		t.Fatal("exported inbox entry repeated", e)
	}
}

func TestTelemetryHTTPDoesNotLoseLateCommitOrRequireRuntimeToDrainInbox(t *testing.T) {
	runtime, inbox := telemetryPair(t)
	ctx := context.Background()
	id := submit(t, runtime, basicSnapshot("http://127.0.0.1"))
	tx, e := runtime.DB.Begin(ctx)
	if e != nil {
		t.Fatal(e)
	}
	defer tx.Rollback(ctx)
	var low, high int64
	if e = tx.QueryRow(ctx, "INSERT INTO events(run_id,kind,payload) VALUES($1,'late','{}') RETURNING seq", id).Scan(&low); e != nil {
		t.Fatal(e)
	}
	if e = runtime.DB.QueryRow(ctx, "INSERT INTO events(run_id,kind,payload) VALUES($1,'early','{}') RETURNING seq", id).Scan(&high); e != nil {
		t.Fatal(e)
	}
	if high <= low {
		t.Fatal("fixture commit ordering invalid")
	}
	if e = inbox.receiveTelemetry(ctx); e != nil {
		t.Fatal(e)
	}
	if e = tx.Commit(ctx); e != nil {
		t.Fatal(e)
	}
	if e = inbox.receiveTelemetry(ctx); e != nil {
		t.Fatal(e)
	}
	var count int
	if e = inbox.DB.QueryRow(ctx, "SELECT count(*) FROM telemetry_inbox").Scan(&count); e != nil || count != 3 {
		t.Fatal("late committed sequence lost", count, e)
	}
	var delivered int
	if e = runtime.DB.QueryRow(ctx, "SELECT count(*) FROM events WHERE telemetry_delivered_at IS NOT NULL").Scan(&delivered); e != nil || delivered != 3 {
		t.Fatal("runtime delivery receipt missing", e)
	}

	// Invalid service identity cannot claim any events through Runtime's API.
	wrong := *inbox.Remote
	wrong.Token = "wrong-service-token-32-characters-long"
	if e = wrong.Request(ctx, "POST", wrong.RuntimeURL+"/v1/telemetry/claim", map[string]string{"owner": ID()}, nil); e == nil {
		t.Fatal("untrusted consumer claimed events")
	}

	t.Setenv("LANGFUSE_PUBLIC_KEY", "fixture-public")
	t.Setenv("LANGFUSE_SECRET_KEY", "fixture-secret")
	collector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte(`{}`)) }))
	defer collector.Close()
	inbox.Remote.RuntimeURL = "http://127.0.0.1:1"
	if e = inbox.receiveTelemetry(ctx); e == nil {
		t.Fatal("unavailable runtime reported successful ingestion")
	}
	if e = inbox.exportOne(ctx, collector.URL); e != nil {
		t.Fatal("Runtime outage prevented draining accepted inbox", e)
	}
	if e = inbox.DB.QueryRow(ctx, "SELECT count(*) FROM telemetry_inbox WHERE exported_at IS NULL").Scan(&count); e != nil || count != 0 {
		t.Fatal("batch not fully acknowledged", count, e)
	}
}
