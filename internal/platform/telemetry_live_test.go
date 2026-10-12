package platform

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

func TestLangfuseLiveIngestionAndReadback(t *testing.T) {
	base := os.Getenv("TEST_LANGFUSE_URL")
	if base == "" {
		t.Skip("real disposable Langfuse required")
	}
	if os.Getenv("LANGFUSE_PUBLIC_KEY") != "pk-lf-ci-disposable" || os.Getenv("LANGFUSE_SECRET_KEY") != "ci-lf-disposable-only" {
		t.Fatal("only disposable upstream project credentials allowed")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	started := time.Now()
	runtime, inbox := telemetryPair(t)
	id := submit(t, runtime, basicSnapshot("http://127.0.0.1"))
	if _, e := runtime.DB.Exec(ctx, "INSERT INTO events(run_id,kind,payload) VALUES($1,'ci_verified_event',$2)", id, JSON(map[string]string{"private_test_marker": "PRIVATE_EVENT_BODY_MUST_NOT_EXPORT"})); e != nil {
		t.Fatal(e)
	}
	if e := inbox.receiveTelemetry(ctx); e != nil {
		t.Fatal(e)
	}
	if e := inbox.exportOne(ctx, base); e != nil {
		t.Fatal("actual Langfuse rejected OTLP", e)
	}
	var expected int
	if e := inbox.DB.QueryRow(ctx, "SELECT count(*) FROM telemetry_inbox WHERE run_id=$1 AND exported_at IS NOT NULL", id).Scan(&expected); e != nil || expected != 2 {
		t.Fatal("durable exporter acknowledgement", expected, e)
	}
	t.Log("PASS actual Langfuse OTLP accepted durable inbox batch")
	identities := map[string]string{}
	rows, e := inbox.DB.Query(ctx, "SELECT seq,kind FROM telemetry_inbox WHERE run_id=$1", id)
	if e != nil {
		t.Fatal(e)
	}
	for rows.Next() {
		var seq int64
		var kind string
		if e = rows.Scan(&seq, &kind); e != nil {
			t.Fatal(e)
		}
		identities[Hash([]byte(fmt.Sprint(id, seq)))[:16]] = kind
	}
	rows.Close()
	if e = rows.Err(); e != nil {
		t.Fatal(e)
	}
	type observation struct {
		ID      string `json:"id"`
		TraceID string `json:"traceId"`
		Name    string `json:"name"`
	}
	read := func() ([]observation, error) {
		query := url.Values{"traceId": {id}, "fields": {"core,basic,metadata"}, "limit": {"100"}, "fromStartTime": {started.Add(-time.Minute).UTC().Format(time.RFC3339Nano)}, "toStartTime": {started.Add(5 * time.Minute).UTC().Format(time.RFC3339Nano)}}
		req, e := http.NewRequestWithContext(ctx, "GET", strings.TrimRight(base, "/")+"/api/public/v2/observations?"+query.Encode(), nil)
		if e != nil {
			return nil, e
		}
		req.SetBasicAuth(os.Getenv("LANGFUSE_PUBLIC_KEY"), os.Getenv("LANGFUSE_SECRET_KEY"))
		resp, e := (&http.Client{Timeout: 10 * time.Second}).Do(req)
		if e != nil {
			return nil, e
		}
		defer resp.Body.Close()
		b, e := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		if e != nil {
			return nil, e
		}
		if resp.StatusCode != 200 {
			return nil, fmt.Errorf("Langfuse read HTTP %d", resp.StatusCode)
		}
		if strings.Contains(string(b), "PRIVATE_EVENT_BODY_MUST_NOT_EXPORT") {
			t.Fatal("event payload leaked to observability backend")
		}
		var result struct {
			Data []observation `json:"data"`
		}
		e = json.Unmarshal(b, &result)
		return result.Data, e
	}
	wait := func(copies int) {
		t.Helper()
		deadline := time.Now().Add(60 * time.Second)
		for {
			items, e := read()
			if e == nil && len(items) == expected*copies {
				seen := map[string]int{}
				for _, item := range items {
					if item.TraceID != id || identities[item.ID] != item.Name || item.Name == "" {
						t.Fatal("upstream observation does not match durable event identity")
					}
					seen[item.ID]++
				}
				for identity := range identities {
					if seen[identity] != copies {
						t.Fatal("unexpected retransmission multiplicity", seen[identity], copies)
					}
				}
				return
			}
			if time.Now().After(deadline) {
				t.Fatal("export accepted but real observations not readable", e, len(items))
			}
			time.Sleep(time.Second)
		}
	}
	wait(1)
	t.Log("PASS actual v2 observations API returns original trace IDs/event names; private payload excluded")
	// Reproduce a crash after upstream ingest but before local export commit.
	if _, e := inbox.DB.Exec(ctx, "UPDATE telemetry_inbox SET exported_at=NULL"); e != nil {
		t.Fatal(e)
	}
	if e := inbox.exportOne(ctx, base); e != nil {
		t.Fatal(e)
	}
	time.Sleep(3 * time.Second)
	// Langfuse v4 explicitly does not deduplicate ingested observations. A lost
	// acknowledgement is an at-least-once delivery: stable IDs, duplicate rows.
	// https://langfuse.com/faq/all/tracing-data-updates
	wait(2)
	t.Log("PASS retransmission keeps each durable event identity and produces two rows per identity in Langfuse v4; upstream metrics are not exactly-once")
}
