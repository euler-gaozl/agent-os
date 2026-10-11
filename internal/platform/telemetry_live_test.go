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
	type observation struct {
		ID      string `json:"id"`
		TraceID string `json:"traceId"`
		Name    string `json:"name"`
	}
	read := func() ([]observation, error) {
		req, e := http.NewRequestWithContext(ctx, "GET", strings.TrimRight(base, "/")+"/api/public/v2/observations?traceId="+url.QueryEscape(id)+"&fields=core,basic,metadata&limit=100", nil)
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
	wait := func() {
		t.Helper()
		deadline := time.Now().Add(60 * time.Second)
		for {
			items, e := read()
			if e == nil && len(items) == expected {
				seen := map[string]bool{}
				found := false
				for _, item := range items {
					if item.TraceID != id || seen[item.ID] {
						t.Fatal("wrong or duplicate observation identity")
					}
					seen[item.ID] = true
					if item.Name == "ci_verified_event" {
						found = true
					}
				}
				if found {
					return
				}
			}
			if time.Now().After(deadline) {
				t.Fatal("export accepted but real observations not readable", e, len(items))
			}
			time.Sleep(time.Second)
		}
	}
	wait()
	t.Log("PASS actual v2 observations API returns original trace IDs/event names; private payload excluded")
	// Reproduce a crash after upstream ingest but before local export commit.
	if _, e := inbox.DB.Exec(ctx, "UPDATE telemetry_inbox SET exported_at=NULL"); e != nil {
		t.Fatal(e)
	}
	if e := inbox.exportOne(ctx, base); e != nil {
		t.Fatal(e)
	}
	time.Sleep(3 * time.Second)
	wait()
	t.Log("PASS retransmission uses the same upstream observation identities")
}
