package resident

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// These are process-level fault tests against catalog-selected released services.
// They never write execution rows to manufacture cancellation or failure.
func testLifecycle(t *testing.T, ctx context.Context, dir, runtimeURL, storageURL, token string, db *pgxpool.Pool, create func(string) *scenario, finish func(*scenario), phase func(string)) {
	t.Helper()
	temporary := os.Getenv("JOINT_PROCESS_TEMP")
	if temporary == "" {
		t.Fatal("dedicated service temporary directory required")
	}
	initial := temporaryFiles(t, temporary)
	if len(initial) != 0 {
		t.Fatal("service temporary directory was not empty at baseline")
	}
	var reports []object
	for _, name := range []string{"cancel-model", "cancel-committed-tool", "provider-401", "provider-truncated"} {
		phase(name)
		s := create(name)
		select {
		case <-s.Entered:
		case <-ctx.Done():
			t.Fatal("fault barrier not reached", name)
		}
		active := lifecycleSample(t, ctx, dir, name, 1, time.Now())
		before := durablePrefix(t, ctx, db, s.ID, name)
		held := object{}
		if name == "cancel-committed-tool" {
			held = committedHeldEffect(t, ctx, db, s.ID, s.HeldOperation)
			if len(before["notes"]) != 2 {
				t.Fatal("expected both independently committed notes")
			}
		}
		state, e := request(ctx, "GET", runtimeURL+"/v1/runs/"+s.ID+"/working-state?revision=1", token, nil)
		need(t, e)
		if !bytes.Contains(state, []byte("SOURCE-417 actual 17; planned 20 is separate.")) {
			t.Fatal("historical structured state missing before fault", name)
		}
		tempDuring := temporaryFiles(t, temporary)
		triggered := time.Now()
		cancelled := strings.HasPrefix(name, "cancel-")
		if cancelled {
			_, e = request(ctx, "POST", runtimeURL+"/v1/runs/"+s.ID+"/cancel", token, object{})
			need(t, e)
		} else {
			close(s.ReleaseFault)
		}
		want := "failed"
		if cancelled {
			want = "cancelled"
		}
		var terminal struct {
			Status          string
			CancelRequested bool `json:"cancel_requested"`
			State           struct{ Error string }
		}
		until := time.Now().Add(25 * time.Second)
		for {
			b, e := request(ctx, "GET", runtimeURL+"/v1/runs/"+s.ID, token, nil)
			need(t, e)
			need(t, json.Unmarshal(b, &terminal))
			if terminal.Status == want {
				break
			}
			if terminal.Status != "running" || time.Now().After(until) {
				t.Fatal("fault did not converge", name, terminal.Status, terminal.State.Error)
			}
			time.Sleep(25 * time.Millisecond)
		}
		terminalAt := time.Now()
		if terminal.CancelRequested != cancelled || terminal.State.Error == "" {
			t.Fatal("terminal cancellation/error record missing", name)
		}
		select {
		case <-s.RequestEnded:
		case <-time.After(5 * time.Second):
			t.Fatal("provider/tool request still active after termination", name)
		}
		phase(name + "-idle")
		idle := lifecycleSample(t, ctx, dir, name+"-idle", 0, terminalAt)
		after := durablePrefix(t, ctx, db, s.ID, name)
		if string(raw(before)) != string(raw(after)) {
			t.Fatal("committed evidence changed or disappeared on termination", name)
		}
		if name == "cancel-committed-tool" && string(raw(held)) != string(raw(committedHeldEffect(t, ctx, db, s.ID, s.HeldOperation))) {
			t.Fatal("the exact held tool effect changed on cancellation")
		}
		stateAfter, e := request(ctx, "GET", runtimeURL+"/v1/runs/"+s.ID+"/working-state?revision=1", token, nil)
		need(t, e)
		if !bytes.Equal(state, stateAfter) {
			t.Fatal("historical state HTTP response changed", name)
		}
		archives := readLifecycleArchives(t, ctx, storageURL, token, db, s.ID)
		var stats []object
		rows, e := db.Query(ctx, "SELECT kind,status,count(*) FROM calls WHERE run_id=$1 GROUP BY kind,status ORDER BY kind,status", s.ID)
		need(t, e)
		for rows.Next() {
			var kind, status string
			var count int
			need(t, rows.Scan(&kind, &status, &count))
			stats = append(stats, object{"kind": kind, "status": status, "count": count})
		}
		need(t, rows.Err())
		rows.Close()
		var unresolvedTools, unfinishedModels, failedModels, pendingArchives, attempts, uniqueAttempts int
		need(t, db.QueryRow(ctx, "SELECT count(*) FILTER(WHERE kind='tool' AND status IN ('inflight','unknown')),count(*) FILTER(WHERE kind='model' AND status='inflight'),count(*) FILTER(WHERE kind='model' AND status='failed') FROM calls WHERE run_id=$1", s.ID).Scan(&unresolvedTools, &unfinishedModels, &failedModels))
		need(t, db.QueryRow(ctx, "SELECT count(*) FROM harness_archives WHERE run_id=$1 AND batch IS NOT NULL", s.ID).Scan(&pendingArchives))
		need(t, db.QueryRow(ctx, "SELECT count(*),count(DISTINCT a.call_id) FROM model_attempts a JOIN calls c ON c.id=a.call_id WHERE c.run_id=$1", s.ID).Scan(&attempts, &uniqueAttempts))
		wantUnfinished, wantFailed := 0, 0
		if name == "cancel-model" {
			wantUnfinished = 1
		}
		if !cancelled {
			wantFailed = 1
		}
		if unresolvedTools != 0 || unfinishedModels != wantUnfinished || failedModels != wantFailed || pendingArchives != 0 || attempts != uniqueAttempts {
			t.Fatal("fault receipts incorrectly classified", name, stats, pendingArchives, attempts, uniqueAttempts)
		}
		// Cancelled model attempts remain unresolved, because no reply was received;
		// do not fabricate a successful/failed provider receipt or a token count.
		page, e := request(ctx, "GET", runtimeURL+"/v1/runs/"+s.ID+"/calls/page?filter=unresolved", token, nil)
		need(t, e)
		var unresolved struct {
			Items      []struct{ ID, Kind, Status string }
			NextCursor string `json:"next_cursor"`
		}
		need(t, json.Unmarshal(page, &unresolved))
		if len(unresolved.Items) != wantUnfinished || unresolved.NextCursor != "" {
			t.Fatal("unresolved management projection disagrees with retained receipts", name)
		}
		// Read the committed source receipt through the bounded management API.
		s.mu.Lock()
		source, models, tools, failure := s.Source, s.Models, s.Tools, s.Failure
		faultStatus, faultBody, faultWritten := s.FaultStatus, s.FaultBody, s.FaultWritten
		s.mu.Unlock()
		if source == "" || failure != "" || models != attempts {
			t.Fatal("fixture did not exercise intended source/model work", name, failure)
		}
		wantTools := 1
		if name == "cancel-committed-tool" {
			wantTools = 2
		}
		if tools != wantTools || models != 3 {
			t.Fatal("fault boundary call count changed", name, models, tools)
		}
		persistedError := ""
		if !cancelled {
			wantStatus, wantError, wantBody := 401, "model HTTP 401", "synthetic provider rejection"
			if name == "provider-truncated" {
				wantStatus, wantError, wantBody = 200, "model output is incomplete or truncated", `{"choices":`
			}
			if !faultWritten || faultStatus != wantStatus || faultBody != wantBody {
				t.Fatal("intended provider fault was not sent", name)
			}
			var attemptError string
			need(t, db.QueryRow(ctx, "SELECT c.error,a.error FROM calls c JOIN model_attempts a ON a.call_id=c.id WHERE c.run_id=$1 AND c.status='failed'", s.ID).Scan(&persistedError, &attemptError))
			if persistedError != wantError || attemptError != wantError || !strings.Contains(terminal.State.Error, wantError) {
				t.Fatal("provider failure not caused by intended response", name, persistedError, attemptError, terminal.State.Error)
			}
		}
		q := url.Values{"operation_id": {source}, "field": {"response"}, "limit": {"16384"}}
		receipt, e := request(ctx, "GET", runtimeURL+"/v1/runs/"+s.ID+"/calls/record?"+q.Encode(), token, nil)
		need(t, e)
		var record struct {
			Status, Text string
			ValueNull    bool `json:"value_null"`
			NextOffset   *int `json:"next_offset"`
		}
		need(t, json.Unmarshal(receipt, &record))
		if record.Status != "completed" || record.ValueNull || record.Text == "" || record.NextOffset != nil {
			t.Fatal("committed source receipt unavailable", name)
		}
		tempAfter := temporaryFiles(t, temporary)
		if len(tempAfter) != 0 {
			t.Fatal("service temporary files remain after termination", name, tempAfter)
		}
		report := object{"name": name, "run_id": s.ID, "status": terminal.Status, "triggered_at": triggered, "terminal_observed_ms": terminalAt.Sub(triggered).Milliseconds(), "node_exit_observed_ms": idle.Sub(triggered).Milliseconds(), "active_node_observed_at": active, "idle_observed_at": idle, "committed_prefix_sha256": digest(raw(before)), "prefix_rows": prefixCounts(before), "historical_state_http_unchanged": true, "source_receipt_http_read": true, "archive_manifests_read": archives, "calls": stats, "model_requests": models, "tool_invocations": tools, "duplicate_model_attempts": attempts - uniqueAttempts, "pending_archive_batches": pendingArchives, "temporary_files_during": tempDuring, "temporary_files_after": tempAfter}
		report["held_effect"] = held
		report["provider_fault"] = object{"status": faultStatus, "body_sha256": digest([]byte(faultBody)), "written": faultWritten, "persisted_error": persistedError}
		save(t, dir, name+"-lifecycle.json", report)
		reports = append(reports, report)
		// The same Worker must accept and finish useful work after every fault.
		phase(name + "-recovery")
		health := create(name + "-recovery")
		finish(health)
		phase(name + "-recovery-idle")
		lifecycleSample(t, ctx, dir, name+"-recovery-idle", 0, time.Now())
		if files := temporaryFiles(t, temporary); len(files) != 0 {
			t.Fatal("service temporary files remain after recovery", name, files)
		}
		if string(raw(before)) != string(raw(durablePrefix(t, ctx, db, s.ID, name))) {
			t.Fatal("subsequent work modified failed/cancelled task evidence", name)
		}
	}
	save(t, dir, "lifecycle.json", object{"passed": true, "scenarios": reports, "recovery_tasks": 4, "service_temporary_directory": temporary, "temporary_files_baseline": initial, "temporary_files_final": temporaryFiles(t, temporary), "paid_model_calls": 0})
}

func committedHeldEffect(t *testing.T, ctx context.Context, db *pgxpool.Pool, id, operation string) object {
	t.Helper()
	if operation == "" {
		t.Fatal("held tool operation absent")
	}
	var callRow, noteRow, noteID, content, status string
	need(t, db.QueryRow(ctx, "SELECT to_jsonb(c)::text,to_jsonb(d)::text,d.id,d.content,c.status FROM calls c JOIN documents d ON d.id=c.response->>'id' WHERE c.id=$1 AND c.run_id=$2 AND c.kind='tool'", operation, id).Scan(&callRow, &noteRow, &noteID, &content, &status))
	if status != "completed" || content != "Synthetic SOURCE-417 actual 17; planned 20 is separate." {
		t.Fatal("held operation and effect did not commit together")
	}
	return object{"operation_id": operation, "note_id": noteID, "call_sha256": digest([]byte(callRow)), "note_sha256": digest([]byte(noteRow))}
}

func temporaryFiles(t *testing.T, root string) []string {
	t.Helper()
	out := []string{}
	need(t, filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if path == root {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		out = append(out, rel)
		if entry.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("unexpected service temporary symlink")
		}
		return nil
	}))
	return out
}

func durablePrefix(t *testing.T, ctx context.Context, db *pgxpool.Pool, id, scope string) map[string][]string {
	t.Helper()
	out := map[string][]string{}
	queries := map[string]string{
		"completed_calls":  "SELECT to_jsonb(c)::text FROM calls c WHERE run_id=$1 AND status='completed' ORDER BY id",
		"completed_models": "SELECT to_jsonb(m)::text FROM model_attempts m JOIN calls c ON c.id=m.call_id WHERE c.run_id=$1 AND m.status='completed' ORDER BY m.id",
		"working_state":    "SELECT to_jsonb(w)::text FROM run_working_states w WHERE run_id=$1 ORDER BY revision",
		"archives":         "SELECT to_jsonb(a)::text FROM harness_archives a WHERE run_id=$1 ORDER BY seq",
		"notes":            "SELECT to_jsonb(d)::text FROM documents d WHERE scope=$1 ORDER BY id",
	}
	for name, query := range queries {
		arg := id
		if name == "notes" {
			arg = scope
		}
		rows, e := db.Query(ctx, query, arg)
		need(t, e)
		for rows.Next() {
			var value string
			need(t, rows.Scan(&value))
			out[name] = append(out[name], value)
		}
		need(t, rows.Err())
		rows.Close()
		if len(out[name]) == 0 {
			t.Fatal("durable prefix missing", name)
		}
	}
	return out
}

func prefixCounts(prefix map[string][]string) map[string]int {
	counts := map[string]int{}
	for k, rows := range prefix {
		counts[k] = len(rows)
	}
	return counts
}

func lifecycleSample(t *testing.T, ctx context.Context, dir, phase string, nodes int, since time.Time) time.Time {
	t.Helper()
	until := time.Now().Add(15 * time.Second)
	for time.Now().Before(until) && ctx.Err() == nil {
		b, _ := os.ReadFile(filepath.Join(dir, "process-samples.jsonl"))
		var first, last time.Time
		for _, line := range bytes.Split(b, []byte("\n")) {
			var sample struct {
				At        time.Time
				Phase     string
				Processes []struct {
					PID  int
					Role string
				}
			}
			if json.Unmarshal(line, &sample) != nil || sample.Phase != phase || sample.At.Before(since) {
				continue
			}
			count, roots := 0, 0
			for _, p := range sample.Processes {
				if p.Role == "node" {
					count++
				} else if p.Role == "runtime" || p.Role == "storage" || p.Role == "joint-worker-a" {
					roots++
				}
			}
			if count != nodes || roots != 3 {
				first = time.Time{}
				continue
			}
			if first.IsZero() {
				first = sample.At
			}
			last = sample.At
			if last.Sub(first) >= 500*time.Millisecond {
				return last
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("expected stable process samples unavailable", phase, nodes)
	return time.Time{}
}

func readLifecycleArchives(t *testing.T, ctx context.Context, storageURL, token string, db *pgxpool.Pool, id string) int {
	t.Helper()
	rows, e := db.Query(ctx, "SELECT manifest_hash FROM harness_archives WHERE run_id=$1 ORDER BY seq", id)
	need(t, e)
	var hashes []string
	for rows.Next() {
		var h string
		need(t, rows.Scan(&h))
		hashes = append(hashes, h)
	}
	need(t, rows.Err())
	rows.Close()
	previous, end := "", 0
	for _, hash := range hashes {
		b, e := request(ctx, "GET", storageURL+"/artifacts/"+hash, token, nil)
		need(t, e)
		if digest(b) != hash {
			t.Fatal("manifest hash mismatch")
		}
		var m struct {
			RunID    string `json:"run_id"`
			Previous string `json:"previous_manifest"`
			Start    int    `json:"event_start"`
			End      int    `json:"event_end"`
			Bytes    int
			SHA256   string
			Parts    []struct {
				Hash   string
				Bytes  int
				Offset int `json:"offset_bytes"`
			}
		}
		need(t, json.Unmarshal(b, &m))
		if m.RunID != id || m.Previous != previous || m.Start != end {
			t.Fatal("archive chain mismatch")
		}
		var payload []byte
		for _, p := range m.Parts {
			b, e := request(ctx, "GET", storageURL+"/artifacts/"+p.Hash, token, nil)
			need(t, e)
			if digest(b) != p.Hash || len(b) != p.Bytes || len(payload) != p.Offset {
				t.Fatal("archive part mismatch")
			}
			payload = append(payload, b...)
		}
		if len(payload) != m.Bytes || digest(payload) != m.SHA256 {
			t.Fatal("archive content mismatch")
		}
		previous, end = hash, m.End
	}
	if len(hashes) == 0 {
		t.Fatal("no archive read")
	}
	return len(hashes)
}
