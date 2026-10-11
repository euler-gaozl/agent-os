package platform

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// An optional independent exporter consumes the durable event log. It never gates run progress.
func (s *Store) ExportTelemetry(ctx context.Context, baseURL string) error {
	if e := validateEndpoint(baseURL); e != nil {
		return e
	}
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-tick.C:
			if e := s.exportOne(ctx, baseURL); e != nil && !errors.Is(e, pgx.ErrNoRows) {
				slog.Warn("telemetry export deferred", "error", e)
			}
		}
	}
}
func (s *Store) exportOne(ctx context.Context, baseURL string) error {
	tx, e := s.DB.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	var seq int64
	var id, kind string
	var at time.Time
	e = tx.QueryRow(ctx, "SELECT e.seq,e.run_id,e.kind,e.created_at FROM events e WHERE NOT EXISTS(SELECT 1 FROM telemetry_exports x WHERE x.seq=e.seq) ORDER BY e.seq FOR UPDATE OF e SKIP LOCKED LIMIT 1").Scan(&seq, &id, &kind, &at)
	if e != nil {
		return e
	}
	pub, e := s.Secret(ctx, "LANGFUSE_PUBLIC_KEY")
	if e != nil {
		return e
	}
	secret, e := s.Secret(ctx, "LANGFUSE_SECRET_KEY")
	if e != nil {
		return e
	}
	attribute := func(k, v string) map[string]any {
		return map[string]any{"key": k, "value": map[string]string{"stringValue": v}}
	}
	span := map[string]any{"traceId": id, "spanId": Hash([]byte(fmt.Sprint(id, seq)))[:16], "name": kind, "kind": 1, "startTimeUnixNano": strconv.FormatInt(at.UnixNano(), 10), "endTimeUnixNano": strconv.FormatInt(at.Add(time.Nanosecond).UnixNano(), 10), "attributes": []any{attribute("agentos.run_id", id), attribute("agentos.event_sequence", strconv.FormatInt(seq, 10)), attribute("langfuse.trace.name", "Agent OS run"), attribute("langfuse.observation.type", "event")}}
	payload := map[string]any{"resourceSpans": []any{map[string]any{"resource": map[string]any{"attributes": []any{attribute("service.name", "agent-os")}}, "scopeSpans": []any{map[string]any{"scope": map[string]string{"name": "agent-os", "version": "0.3.0"}, "spans": []any{span}}}}}}
	requestCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, e := http.NewRequestWithContext(requestCtx, "POST", strings.TrimRight(baseURL, "/")+"/api/public/otel/v1/traces", bytes.NewReader(JSON(payload)))
	if e != nil {
		return e
	}
	req.SetBasicAuth(pub, secret)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-langfuse-ingestion-version", "4")
	resp, e := externalHTTP.Do(req)
	if e != nil {
		return e
	}
	defer resp.Body.Close()
	body, e := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if e != nil {
		return e
	}
	if resp.StatusCode != 200 {
		return fmt.Errorf("telemetry HTTP %d", resp.StatusCode)
	}
	var ack struct {
		Partial struct {
			Rejected json.RawMessage `json:"rejectedSpans"`
		} `json:"partialSuccess"`
	}
	if len(body) > 0 {
		if e = json.Unmarshal(body, &ack); e != nil {
			return errors.New("invalid telemetry acknowledgement")
		}
	}
	if rejected := strings.Trim(string(ack.Partial.Rejected), "\""); rejected != "" && rejected != "0" {
		return errors.New("telemetry reported partial rejection; event remains queued")
	}
	if _, e = tx.Exec(ctx, "INSERT INTO telemetry_exports(seq) VALUES($1) ON CONFLICT DO NOTHING", seq); e != nil {
		return e
	}
	return tx.Commit(ctx)
}
