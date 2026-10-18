// Package resident measures independently released executables, never imports
// service implementation, and uses disposable databases. Provider, Registry and
// ToolHub routing are controlled fixtures; Runtime, Worker, Node and Storage are real.
package resident

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type object = map[string]any

const engine = "dsh-source-639ed015-resident-v2"

func raw(v any) []byte {
	b, e := json.Marshal(v)
	if e != nil {
		panic(e)
	}
	return b
}
func digest(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func need(t *testing.T, e error) {
	t.Helper()
	if e != nil {
		t.Fatal(e)
	}
}
func save(t *testing.T, dir, name string, v any) {
	t.Helper()
	need(t, os.WriteFile(filepath.Join(dir, name), raw(v), 0600))
}
func port(t *testing.T) string {
	t.Helper()
	l, e := net.Listen("tcp", "127.0.0.1:0")
	need(t, e)
	a := l.Addr().String()
	need(t, l.Close())
	return a
}

func request(ctx context.Context, method, endpoint, token string, body any) ([]byte, error) {
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(raw(body))
	}
	r, e := http.NewRequestWithContext(ctx, method, endpoint, reader)
	if e != nil {
		return nil, e
	}
	r.Header.Set("Authorization", "Bearer "+token)
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Idempotency-Key", digest([]byte(endpoint+string(raw(body)))))
	c := http.Client{Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return fmt.Errorf("redirect refused") }}
	res, e := c.Do(r)
	if e != nil {
		return nil, e
	}
	defer res.Body.Close()
	b, e := io.ReadAll(io.LimitReader(res.Body, 32<<20))
	if e != nil {
		return nil, e
	}
	if res.StatusCode >= 300 {
		return nil, fmt.Errorf("fixture HTTP %d %s: %.300s", res.StatusCode, r.URL.Path, b)
	}
	return b, nil
}

type child struct {
	cmd  *exec.Cmd
	done chan error
	log  *os.File
}

func start(t *testing.T, ctx context.Context, dir, name, binary string, config map[string]string) *child {
	t.Helper()
	file := filepath.Join(dir, name+".config.json")
	save(t, dir, name+".config.json", config)
	log, e := os.Create(filepath.Join(dir, name+".log"))
	need(t, e)
	c := exec.CommandContext(ctx, binary, "--config", file)
	c.Dir = dir
	c.Stdout = log
	c.Stderr = log
	for _, key := range []string{"PATH", "SystemRoot", "WINDIR", "TEMP", "TMP", "LANG"} {
		v := os.Getenv(key)
		if (key == "TEMP" || key == "TMP") && os.Getenv("JOINT_PROCESS_TEMP") != "" {
			v = os.Getenv("JOINT_PROCESS_TEMP")
		}
		if v != "" {
			c.Env = append(c.Env, key+"="+v)
		}
	}
	need(t, c.Start())
	p := &child{c, make(chan error, 1), log}
	go func() { p.done <- c.Wait(); close(p.done) }()
	t.Cleanup(func() {
		_ = p.cmd.Process.Kill()
		select {
		case <-p.done:
		case <-time.After(5 * time.Second):
			t.Error("fixture child did not stop", name)
		}
		_ = log.Close()
	})
	return p
}
func ready(t *testing.T, ctx context.Context, endpoint, token string) {
	t.Helper()
	until := time.Now().Add(15 * time.Second)
	for time.Now().Before(until) {
		if _, e := request(ctx, "GET", endpoint+"/readyz", token, nil); e == nil {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("fixture service did not become ready", endpoint)
}
func database(t *testing.T, ctx context.Context, admin *pgxpool.Pool, suffix, kind, migrator string, roles ...string) (*pgxpool.Pool, map[string]string) {
	t.Helper()
	name := "joint_" + suffix + "_" + kind
	// The outer controller removes these only after checking every process has
	// exited. go test's timeout can bypass t.Cleanup entirely.
	save(t, os.Getenv("JOINT_EVIDENCE"), kind+"-database.json", object{"database": name, "roles": roles})
	for _, role := range roles {
		_, e := admin.Exec(ctx, "CREATE ROLE "+pgx.Identifier{role}.Sanitize()+" LOGIN PASSWORD 'fixture-only'")
		need(t, e)
	}
	_, e := admin.Exec(ctx, "CREATE DATABASE "+pgx.Identifier{name}.Sanitize()+" TEMPLATE template0")
	need(t, e)
	u, e := url.Parse(os.Getenv("JOINT_DATABASE_URL"))
	need(t, e)
	u.Path = "/" + name
	m := exec.CommandContext(ctx, migrator, "--role", roles[0])
	if len(roles) > 1 {
		m.Args = append(m.Args, "--worker-role", roles[1])
	}
	m.Env = append(os.Environ(), "MIGRATION_DATABASE_URL="+u.String())
	b, e := m.CombinedOutput()
	if e != nil {
		t.Fatalf("owner migration failed: %s", b)
	}
	p, e := pgxpool.New(ctx, u.String())
	need(t, e)
	t.Cleanup(p.Close)
	dsns := map[string]string{}
	for _, role := range roles {
		u.User = url.UserPassword(role, "fixture-only")
		dsns[role] = u.String()
	}
	return p, dsns
}

type scenario struct {
	mu            sync.Mutex
	Name          string        `json:"name"`
	Target        int           `json:"model_request_budget"`
	ID            string        `json:"run_id"`
	Models        int           `json:"model_requests"`
	Ordinary      int           `json:"ordinary_requests"`
	Summaries     int           `json:"compact_requests"`
	Tools         int           `json:"tool_invocations"`
	Source        string        `json:"source_receipt"`
	AfterCompact  bool          `json:"state_after_compact"`
	Failure       string        `json:"failure,omitempty"`
	Kill          bool          `json:"kill"`
	Blocked       bool          `json:"-"`
	KillPoint     chan struct{} `json:"-"`
	Barrier       chan struct{} `json:"-"`
	Entered       chan struct{} `json:"-"`
	Registered    chan struct{} `json:"-"`
	ReleaseFault  chan struct{} `json:"-"`
	RequestEnded  chan struct{} `json:"-"`
	FaultStatus   int           `json:"fault_status,omitempty"`
	FaultBody     string        `json:"fault_body,omitempty"`
	FaultWritten  bool          `json:"fault_written,omitempty"`
	HeldOperation string        `json:"held_operation,omitempty"`
	KilledAt      time.Time     `json:"killed_at,omitempty"`
	ClaimedAt     time.Time     `json:"claimed_at,omitempty"`
	FirstNewAt    time.Time     `json:"first_new_request_at,omitempty"`
	Started       time.Time     `json:"started_at"`
	Finished      time.Time     `json:"finished_at"`
}

func (s *scenario) model(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	select {
	case <-s.Registered:
	case <-r.Context().Done():
		return
	}
	if os.Getenv("JOINT_TIMEOUT_FAULT") == "1" && s.Name == "single-20" && s.Models == 0 {
		// Keep the real Worker/Node request active until go test's global panic.
		// The outer controller requires this barrier and a later live Node sample.
		if e := os.WriteFile(filepath.Join(os.Getenv("JOINT_EVIDENCE"), "timeout-held-model.json"), raw(object{"name": s.Name, "run_id": s.ID, "at": time.Now()}), 0600); e != nil {
			http.Error(w, "fault barrier unavailable", 500)
			return
		}
		<-r.Context().Done()
		return
	}
	if s.Models == 0 && s.Barrier != nil {
		close(s.Entered)
		select {
		case <-s.Barrier:
		case <-r.Context().Done():
			return
		}
	}
	var body struct {
		Messages  []struct{ Role, Content string }
		MaxTokens int `json:"max_tokens"`
	}
	if json.NewDecoder(io.LimitReader(r.Body, 2<<20)).Decode(&body) != nil || len(body.Messages) == 0 {
		http.Error(w, "bad fixture request", 400)
		return
	}
	s.Models++
	if !s.KilledAt.IsZero() && s.FirstNewAt.IsZero() {
		s.FirstNewAt = time.Now()
	}
	if body.MaxTokens != 2048 {
		s.Failure = "output budget changed"
	}
	message := object{"role": "assistant"}
	finish := "stop"
	if strings.Contains(body.Messages[len(body.Messages)-1].Content, "Create a concise continuity checkpoint") {
		s.Summaries++
		message["content"] = "Synthetic checkpoint omits source quantities deliberately."
	} else {
		s.Ordinary++
		if s.Ordinary == 3 && (s.Name == "cancel-model" || s.Name == "provider-401" || s.Name == "provider-truncated") {
			close(s.Entered)
			defer close(s.RequestEnded)
			select {
			case <-s.ReleaseFault:
			case <-r.Context().Done():
				return
			}
			if s.Name == "provider-401" {
				s.FaultStatus, s.FaultBody = http.StatusUnauthorized, "synthetic provider rejection"
			} else if s.Name == "provider-truncated" {
				s.FaultStatus, s.FaultBody = http.StatusOK, `{"choices":`
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(s.FaultStatus)
			n, err := w.Write([]byte(s.FaultBody))
			s.FaultWritten = err == nil && n == len(s.FaultBody)
			return
		}
		var view struct {
			Revision int
			State    *struct {
				Observations []struct {
					Text     string
					Receipts []string
				}
			}
		}
		for _, m := range body.Messages {
			if n := strings.Index(m.Content, "BEGIN_WORKING_STATE_DATA\n"); n >= 0 {
				data := strings.SplitN(m.Content[n+len("BEGIN_WORKING_STATE_DATA\n"):], "\nEND_WORKING_STATE_DATA", 2)[0]
				var projected struct{ View json.RawMessage }
				if json.Unmarshal([]byte(data), &projected) == nil {
					_ = json.Unmarshal(projected.View, &view)
				}
			}
		}
		if s.Ordinary >= 3 && (view.State == nil || len(view.State.Observations) != 1 || view.State.Observations[0].Text != "SOURCE-417 actual 17; planned 20 is separate." || len(view.State.Observations[0].Receipts) != 1 || view.State.Observations[0].Receipts[0] != s.Source) {
			s.Failure = "durable state projection missing or altered"
		}
		if s.Ordinary >= 3 && s.Summaries > 0 {
			s.AfterCompact = true
		}
		call := func(name string, args any) {
			finish = "tool_calls"
			message["tool_calls"] = []any{object{"id": fmt.Sprintf("fixture-%d", s.Models), "type": "function", "function": object{"name": name, "arguments": string(raw(args))}}}
		}
		switch {
		case s.Ordinary == 2:
			for i := len(body.Messages) - 1; i >= 0; i-- {
				if body.Messages[i].Role == "tool" {
					var v struct {
						Receipt struct {
							OperationID string `json:"operation_id"`
							Committed   bool
						}
					}
					_ = json.Unmarshal([]byte(body.Messages[i].Content), &v)
					if v.Receipt.Committed {
						s.Source = v.Receipt.OperationID
					}
					break
				}
			}
			if s.Source == "" {
				s.Failure = "source committed receipt absent"
			}
			call("working_state_update", object{"expected_revision": view.Revision, "reason": "Preserve synthetic evidence across compaction", "state": object{"format": 1, "phase": "compare actual and planned", "questions": []any{}, "observations": []any{object{"id": "actual", "kind": "observation", "text": "SOURCE-417 actual 17; planned 20 is separate.", "receipts": []string{s.Source}}}, "conflicts": []any{}, "next_steps": []any{}}})
		case s.Models >= s.Target-1:
			message["content"] = "SOURCE-417 actual 17; planned 20 is separate."
		default:
			call("note_save", object{"kind": "fact", "title": "joint fixture", "content": "Synthetic SOURCE-417 actual 17; planned 20 is separate.", "source": "fixture://" + s.Name})
			message["content"] = strings.Repeat("synthetic history ", 240) // ~4 KiB output; fixed for all workloads.
		}
	}
	time.Sleep(25 * time.Millisecond) // Controlled local provider latency, not real provider latency.
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(raw(object{"choices": []any{object{"message": message, "finish_reason": finish}}, "usage": object{"prompt_tokens": 4000, "completion_tokens": 1100, "total_tokens": 5100}}))
}

func TestResidentReleasedServices(t *testing.T) {
	if os.Getenv("JOINT_EVIDENCE") == "" {
		t.Skip("explicit released-service acceptance not configured")
	}
	dir := os.Getenv("JOINT_EVIDENCE")
	ctx, cancel := context.WithTimeout(context.Background(), 7*time.Minute)
	defer cancel()
	admin, e := pgxpool.New(ctx, os.Getenv("JOINT_DATABASE_URL"))
	need(t, e)
	t.Cleanup(admin.Close)
	var nonce [8]byte
	_, e = rand.Read(nonce[:])
	need(t, e)
	suffix := hex.EncodeToString(nonce[:])
	role := "joint_" + suffix
	db, dsn := database(t, ctx, admin, suffix, "runtime", os.Getenv("JOINT_RUNTIME_MIGRATOR"), role+"_runtime", role+"_worker")
	storageDB, storageDSN := database(t, ctx, admin, suffix, "storage", os.Getenv("JOINT_STORAGE_MIGRATOR"), role+"_storage")
	tokens := map[string]string{}
	peers := map[string]string{}
	for _, r := range []string{"runtime", "storage", "worker", "control", "toolhub"} {
		tokens[r] = "fixture-joint-" + suffix + "-" + r
		peers[r] = digest([]byte(tokens[r]))
	}
	var smu sync.Mutex
	scenarios := map[string]*scenario{}
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		name := strings.Split(strings.TrimPrefix(r.URL.Path, "/"), "/")[0]
		smu.Lock()
		s := scenarios[name]
		smu.Unlock()
		if s == nil {
			http.NotFound(w, r)
			return
		}
		s.model(w, r)
	}))
	t.Cleanup(model.Close)
	registry := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		parts := strings.Split(r.URL.Path, "/")
		if len(parts) != 6 || parts[3] != "agent" {
			http.NotFound(w, r)
			return
		}
		smu.Lock()
		s := scenarios[parts[4]]
		smu.Unlock()
		if s == nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(raw(object{"kind": "agent", "id": s.Name, "revision": 1, "spec": object{"name": "Synthetic joint resource measurement", "prompt": "Preserve actual and planned quantities separately. Synthetic fixture only.", "tools": []string{"note_save"}, "model": object{"base_url": model.URL + "/" + s.Name, "model": "fixture-only", "max_tokens": 2048}, "max_steps": s.Target, "max_model_attempts": s.Target, "model_token_budget": 1000000, "context_tokens": 8192, "context_bytes": 64000, "max_children": 0}}))
	}))
	t.Cleanup(registry.Close)
	runtimeAddr, storageAddr := port(t), port(t)
	runtimeURL, storageURL := "http://"+runtimeAddr, "http://"+storageAddr
	hub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, e := io.ReadAll(io.LimitReader(r.Body, 2<<20))
		if e != nil {
			http.Error(w, "read failed", 400)
			return
		}
		var inv struct {
			RunID       string `json:"run_id"`
			OperationID string `json:"operation_id"`
		}
		_ = json.Unmarshal(b, &inv)
		smu.Lock()
		var selected *scenario
		for _, s := range scenarios {
			if s.ID == inv.RunID {
				selected = s
				break
			}
		}
		smu.Unlock()
		if selected == nil {
			http.Error(w, "run missing", 400)
			return
		}
		var input any
		_ = json.Unmarshal(b, &input)
		result, e := request(r.Context(), "POST", runtimeURL+"/invoke", tokens["toolhub"], input)
		if e != nil {
			http.Error(w, e.Error(), 500)
			return
		}
		selected.mu.Lock()
		selected.Tools++
		cancelTool := selected.Name == "cancel-committed-tool" && selected.Tools == 2
		if cancelTool {
			selected.HeldOperation = inv.OperationID
		}
		block := selected.Kill && !selected.Blocked && selected.Models >= selected.Target-5
		if block {
			selected.Blocked = true
			close(selected.KillPoint)
		}
		selected.mu.Unlock()
		if cancelTool {
			// The local note and receipt have committed in the real Runtime;
			// only the HTTP reply to the Worker is withheld.
			close(selected.Entered)
			defer close(selected.RequestEnded)
			<-r.Context().Done()
			return
		}
		if block {
			<-r.Context().Done()
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(result)
	}))
	t.Cleanup(hub.Close)
	base := map[string]string{"SERVICE_PEERS": string(raw(peers)), "REGISTRY_URL": registry.URL, "TOOLHUB_URL": hub.URL, "RUNTIME_URL": runtimeURL, "STORAGE_URL": storageURL, "DB_MAX_CONNS": "3", "GOMEMLIMIT": "96MiB"}
	conf := func(name, roleName, addr, dburl string) map[string]string {
		m := map[string]string{}
		for k, v := range base {
			m[k] = v
		}
		m["INSTANCE_ID"] = name
		m["SERVICE_TOKEN"] = tokens[roleName]
		m["LISTEN"] = addr
		m["DATABASE_URL"] = dburl
		return m
	}
	rc := conf("joint-runtime", "runtime", runtimeAddr, dsn[role+"_runtime"])
	rc["DEFAULT_RUN_ENGINE"] = engine
	rp := start(t, ctx, dir, "runtime", os.Getenv("JOINT_RUNTIME"), rc)
	sp := start(t, ctx, dir, "storage", os.Getenv("JOINT_STORAGE"), conf("joint-storage", "storage", storageAddr, storageDSN[role+"_storage"]))
	ready(t, ctx, runtimeURL, tokens["control"])
	ready(t, ctx, storageURL, tokens["control"])
	processes := object{"runtime": rp.cmd.Process.Pid, "storage": sp.cmd.Process.Pid}
	workers := map[string]*child{}
	worker := func(name string) {
		addr := port(t)
		wc := conf(name, "worker", addr, dsn[role+"_worker"])
		wc["AGENTOS_NODE"] = os.Getenv("JOINT_NODE")
		wc["DSH_SOURCE_RUNNER"] = os.Getenv("JOINT_V1")
		wc["DSH_RESIDENT_RUNNER"] = os.Getenv("JOINT_V2")
		wc["GOMEMLIMIT"] = "192MiB"
		p := start(t, ctx, dir, name, os.Getenv("JOINT_WORKER"), wc)
		workers[name] = p
		processes[name] = p.cmd.Process.Pid
		save(t, dir, "processes.json", processes)
		ready(t, ctx, "http://"+addr, tokens["worker"])
	}
	worker("joint-worker-a")
	phase := func(name string) { save(t, dir, "phase.json", object{"phase": name, "at": time.Now()}) }
	phase("idle-before")
	time.Sleep(time.Second)
	parallelBarrier := make(chan struct{})
	create := func(name string, target int, kill bool) *scenario {
		s := &scenario{Name: name, Target: target, Kill: kill, KillPoint: make(chan struct{}), Entered: make(chan struct{}), Registered: make(chan struct{}), ReleaseFault: make(chan struct{}), RequestEnded: make(chan struct{}), Started: time.Now()}
		if strings.HasPrefix(name, "parallel-") {
			s.Barrier = parallelBarrier
		}
		smu.Lock()
		scenarios[name] = s
		smu.Unlock()
		b, e := request(ctx, "POST", runtimeURL+"/v1/runs", tokens["control"], object{"agent": object{"id": name, "revision": 1}, "task": "Synthetic resource and recovery fixture " + name})
		need(t, e)
		var out struct{ ID string }
		need(t, json.Unmarshal(b, &out))
		smu.Lock()
		s.ID = out.ID
		smu.Unlock()
		close(s.Registered)
		return s
	}
	type run struct {
		ID, Status, Owner, Engine string
		Fence                     int
		UpdatedAt                 time.Time `json:"updated_at"`
		State                     struct {
			Result, Error   string
			HarnessArtifact string `json:"harness_artifact"`
		}
	}
	get := func(s *scenario) run {
		b, e := request(ctx, "GET", runtimeURL+"/v1/runs/"+s.ID, tokens["control"], nil)
		need(t, e)
		var r run
		need(t, json.Unmarshal(b, &r))
		return r
	}
	finish := func(s *scenario) {
		for {
			r := get(s)
			if r.Status == "completed" {
				s.Finished = r.UpdatedAt
				if r.Engine != engine || r.State.Result != "SOURCE-417 actual 17; planned 20 is separate." {
					t.Fatal("incorrect terminal output")
				}
				break
			}
			if r.Status == "failed" || r.Status == "waiting_unknown" {
				t.Fatal("run did not complete", s.Name, r.Status, r.State.Error)
			}
			if ctx.Err() != nil {
				t.Fatal(ctx.Err())
			}
			time.Sleep(30 * time.Millisecond)
		}
		s.mu.Lock()
		failure, models, ordinary, tools, summaries, after := s.Failure, s.Models, s.Ordinary, s.Tools, s.Summaries, s.AfterCompact
		s.mu.Unlock()
		if failure != "" || models < s.Target-1 || models > s.Target || tools != ordinary-2 || summaries == 0 || !after {
			t.Fatalf("fixture invariant %s: failure=%q models=%d target=%d ordinary=%d tools=%d summaries=%d after=%t", s.Name, failure, models, s.Target, ordinary, tools, summaries, after)
		}
		var attempts, duplicates, unconfirmed, states, notes int
		need(t, db.QueryRow(ctx, "SELECT count(*),count(*)-count(DISTINCT a.call_id) FROM model_attempts a JOIN calls c ON c.id=a.call_id WHERE c.run_id=$1", s.ID).Scan(&attempts, &duplicates))
		need(t, db.QueryRow(ctx, "SELECT count(*) FROM harness_archives WHERE run_id=$1 AND (manifest_hash='' OR batch IS NOT NULL)", s.ID).Scan(&unconfirmed))
		need(t, db.QueryRow(ctx, "SELECT count(*) FROM run_working_states WHERE run_id=$1", s.ID).Scan(&states))
		need(t, db.QueryRow(ctx, "SELECT count(*) FROM calls WHERE run_id=$1 AND kind='tool' AND status='completed'", s.ID).Scan(&notes))
		if attempts != models || duplicates != 0 || unconfirmed != 0 || states != 1 || notes != tools {
			t.Fatal("durable counts mismatch", attempts, duplicates, unconfirmed, states, notes, tools)
		}
		// Walk every committed manifest and read exact part bytes through real Storage HTTP.
		rows, e := db.Query(ctx, "SELECT manifest_hash FROM harness_archives WHERE run_id=$1 ORDER BY seq", s.ID)
		need(t, e)
		var hashes []string
		for rows.Next() {
			var h string
			need(t, rows.Scan(&h))
			hashes = append(hashes, h)
		}
		need(t, rows.Err())
		rows.Close()
		previous := ""
		end, total := 0, 0
		compact := false
		for _, h := range hashes {
			b, e := request(ctx, "GET", storageURL+"/artifacts/"+h, tokens["control"], nil)
			need(t, e)
			if digest(b) != h {
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
					Offset int `json:"offset_bytes"`
					Bytes  int
				}
			}
			need(t, json.Unmarshal(b, &m))
			if m.RunID != s.ID || m.Previous != previous || m.Start != end {
				t.Fatal("archive chain broken")
			}
			var data []byte
			for _, part := range m.Parts {
				b, e := request(ctx, "GET", storageURL+"/artifacts/"+part.Hash, tokens["control"], nil)
				need(t, e)
				if digest(b) != part.Hash || len(data) != part.Offset || len(b) != part.Bytes {
					t.Fatal("archive part mismatch")
				}
				data = append(data, b...)
			}
			if len(data) != m.Bytes || digest(data) != m.SHA256 {
				t.Fatal("archive payload mismatch")
			}
			compact = compact || bytes.Contains(data, []byte("compaction/end"))
			total += len(data)
			previous = h
			end = m.End
		}
		if previous != get(s).State.HarnessArtifact || !compact {
			t.Fatal("final archive or compact missing")
		}
		b, e := request(ctx, "GET", runtimeURL+"/v1/runs/"+s.ID+"/working-state?revision=1", tokens["control"], nil)
		need(t, e)
		if !bytes.Contains(b, []byte("SOURCE-417")) {
			t.Fatal("historical state missing")
		}
		started := time.Now()
		calls, e := request(ctx, "GET", runtimeURL+"/v1/runs/"+s.ID+"/calls", tokens["control"], nil)
		need(t, e)
		callsMS := time.Since(started).Milliseconds()
		var dbbytes, storagebytes int64
		need(t, db.QueryRow(ctx, "SELECT pg_database_size(current_database())").Scan(&dbbytes))
		need(t, storageDB.QueryRow(ctx, "SELECT pg_database_size(current_database())").Scan(&storagebytes))
		save(t, dir, s.Name+".json", object{"scenario": s, "archive_count": len(hashes), "event_bytes": total, "calls_response_bytes": len(calls), "calls_read_ms": callsMS, "runtime_database_bytes": dbbytes, "storage_database_bytes": storagebytes, "unconfirmed_batches": unconfirmed, "duplicate_attempts": duplicates, "historical_state_read": true, "all_archive_parts_read": true})
	}
	if os.Getenv("JOINT_LIFECYCLE") == "1" {
		testLifecycle(t, ctx, dir, runtimeURL, storageURL, tokens["control"], db, func(name string) *scenario { return create(name, 20, false) }, finish, phase)
		return
	}
	for _, n := range []int{20, 50} {
		name := fmt.Sprintf("single-%d", n)
		phase(name)
		s := create(name, n, false)
		finish(s)
		phase(name + "-idle")
		time.Sleep(time.Second)
	}
	worker("joint-worker-b")
	phase("takeover-100")
	s := create("takeover-100", 100, true)
	select {
	case <-s.KillPoint:
	case <-ctx.Done():
		t.Fatal("kill point not reached")
	}
	r := get(s)
	s.mu.Lock()
	s.KilledAt = time.Now()
	s.mu.Unlock()
	need(t, workers[r.Owner].cmd.Process.Kill())
	select {
	case <-workers[r.Owner].done:
	case <-ctx.Done():
		t.Fatal("worker kill timeout")
	}
	// Do not shorten or rewrite the lease. The other released Worker takes over naturally.
	for {
		v := get(s)
		if v.Fence > r.Fence {
			s.mu.Lock()
			s.ClaimedAt = time.Now()
			s.mu.Unlock()
			break
		}
		if ctx.Err() != nil {
			t.Fatal(ctx.Err())
		}
		time.Sleep(20 * time.Millisecond)
	}
	finish(s)
	if final := get(s); final.Fence != r.Fence+1 || final.Owner == r.Owner {
		t.Fatal("takeover owner/fence not replaced exactly once")
	}
	phase("takeover-idle")
	time.Sleep(time.Second)
	worker("joint-worker-c")
	phase("parallel-50")
	a, b := create("parallel-a", 50, false), create("parallel-b", 50, false)
	for _, pending := range []*scenario{a, b} {
		select {
		case <-pending.Entered:
		case <-ctx.Done():
			t.Fatal("both Workers did not reach parallel barrier")
		}
	}
	ra, rb := get(a), get(b)
	if ra.Status != "running" || rb.Status != "running" || ra.Owner == rb.Owner {
		t.Fatal("parallel runs were not running on distinct Workers")
	}
	save(t, dir, "parallel-barrier.json", object{"at": time.Now(), "first": ra, "second": rb})
	close(parallelBarrier)
	finish(a)
	finish(b)
	for i := 0; i < 3; i++ {
		name := fmt.Sprintf("continuous-%d", i)
		phase(name)
		finish(create(name, 20, false))
		phase(name + "-idle")
		time.Sleep(time.Second)
	}
	phase("idle-after")
	time.Sleep(2 * time.Second)
	for _, roleName := range []string{"runtime", "storage"} {
		endpoint := runtimeURL
		if roleName == "storage" {
			endpoint = storageURL
		}
		b, e := request(ctx, "GET", endpoint+"/metrics", tokens["control"], nil)
		need(t, e)
		need(t, os.WriteFile(filepath.Join(dir, roleName+"-metrics.txt"), b, 0600))
	}
	save(t, dir, "result.json", object{"passed": true, "engine": engine, "scenarios": len(scenarios), "paid_model_calls": 0, "forced_gc": false, "scope": "released Windows Runtime, Worker, Node and Storage with separate restricted databases; Registry/provider/ToolHub routing fixtures; no real provider throughput or physical HA claim"})
}
