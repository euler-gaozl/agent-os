package platform

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const testToken = "test-only-service-token-32-characters-long"

func testStore(t testing.TB) (*Store, string) {
	t.Helper()
	entry, pathErr := filepath.Abs("../../harness/runner.mjs")
	if pathErr != nil {
		t.Fatal(pathErr)
	}
	t.Setenv("DSH_RUNNER", entry)
	base := os.Getenv("TEST_DATABASE_URL")
	if base == "" {
		t.Skip("TEST_DATABASE_URL absent; real PostgreSQL integration test not executed")
	}
	ctx := context.Background()
	admin, e := Open(ctx, base)
	if e != nil {
		t.Fatal(e)
	}
	schema := "test_" + ID()
	if _, e = admin.DB.Exec(ctx, "CREATE SCHEMA "+schema); e != nil {
		t.Fatal(e)
	}
	u, e := url.Parse(base)
	if e != nil {
		t.Fatal(e)
	}
	q := u.Query()
	q.Set("search_path", schema)
	u.RawQuery = q.Encode()
	dsn := u.String()
	s, e := Open(ctx, dsn)
	if e != nil {
		t.Fatal(e)
	}
	if e = s.Migrate(ctx); e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() {
		s.DB.Close()
		_, e := admin.DB.Exec(context.Background(), "DROP SCHEMA "+schema+" CASCADE")
		if e != nil {
			t.Error(e)
		}
		admin.DB.Close()
	})
	return s, dsn
}
func basicSnapshot(endpoint string) Snapshot {
	return Snapshot{AgentRef: Ref{"test", 1}, Agent: Agent{Name: "Test agent", Prompt: "Use recorded facts only.", Tools: []string{"note_save", "knowledge_search", "spawn_agent"}, Model: ModelConfig{BaseURL: endpoint, Model: "fixture-only"}, MaxSteps: 6, ContextBytes: 64000, MaxChildren: 2}}
}
func submit(t *testing.T, s *Store, snap Snapshot) string {
	t.Helper()
	id, e := s.Submit(context.Background(), ID(), "integration fixture; not research data", snap, []string{"Do not predict prices."})
	if e != nil {
		t.Fatal(e)
	}
	return id
}
func claim(t *testing.T, s *Store, owner string) Run {
	t.Helper()
	r, e := s.Claim(context.Background(), owner, 10*time.Second)
	if e != nil {
		t.Fatal(e)
	}
	return r
}
func invocation(r Run) Invocation {
	return Invocation{RunID: r.ID, Owner: r.Owner, Fence: r.Fence, RuleRevision: r.RuleRevision, OperationID: r.ID + "/tool/1/save", Name: "note_save", Arguments: json.RawMessage(`{"kind":"fact","title":"Test observation","content":"fixture value 42","source":"test://fixture"}`)}
}

func TestConcurrentClaimsAndFencing(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	for i := 0; i < 12; i++ {
		submit(t, s, basicSnapshot("http://127.0.0.1"))
	}
	var wg sync.WaitGroup
	var mu sync.Mutex
	claimed := map[string]Run{}
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			r, e := s.Claim(ctx, fmt.Sprint("worker-", i), 10*time.Second)
			if e != nil {
				t.Error(e)
				return
			}
			mu.Lock()
			defer mu.Unlock()
			if _, exists := claimed[r.ID]; exists {
				t.Error("duplicate claim")
			}
			claimed[r.ID] = r
		}(i)
	}
	wg.Wait()
	if len(claimed) != 12 {
		t.Fatal("not all runs claimed")
	}
	var old Run
	for _, r := range claimed {
		old = r
		break
	}
	_, e := s.DB.Exec(ctx, "UPDATE runs SET lease_until=now()-interval '1 second' WHERE id=$1", old.ID)
	if e != nil {
		t.Fatal(e)
	}
	newOwner, e := s.Claim(ctx, "replacement", 10*time.Second)
	if e != nil {
		t.Fatal(e)
	}
	if newOwner.ID != old.ID || newOwner.Fence <= old.Fence {
		t.Fatal("takeover did not advance fence")
	}
	if _, e = s.LocalTool(ctx, invocation(old)); !errors.Is(e, ErrFence) {
		t.Fatalf("stale worker effect accepted: %v", e)
	}
	if e = s.Save(ctx, old, "completed"); !errors.Is(e, ErrFence) {
		t.Fatalf("stale checkpoint accepted: %v", e)
	}
}

func TestAtomicToolEffectAndReceipt(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	snap := basicSnapshot("http://127.0.0.1")
	key := ID()
	id, e := s.Submit(ctx, key, "same task", snap, nil)
	if e != nil {
		t.Fatal(e)
	}
	again, e := s.Submit(ctx, key, "same task", snap, nil)
	if e != nil || id != again {
		t.Fatal("submission is not idempotent", e)
	}
	if _, e = s.Submit(ctx, key, "different", snap, nil); e == nil {
		t.Fatal("key/input mismatch accepted")
	}
	r := claim(t, s, "one")
	inv := invocation(r)
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, e := s.LocalTool(ctx, inv); e != nil {
				t.Error(e)
			}
		}()
	}
	wg.Wait()
	var docs, calls int
	s.DB.QueryRow(ctx, "SELECT count(*) FROM documents").Scan(&docs)
	s.DB.QueryRow(ctx, "SELECT count(*) FROM calls").Scan(&calls)
	if docs != 1 || calls != 1 {
		t.Fatalf("duplicate effect: docs=%d calls=%d", docs, calls)
	}
	inv.Arguments = json.RawMessage(`{"kind":"fact","title":"Changed","content":"different","source":"test://fixture"}`)
	if _, e = s.LocalTool(ctx, inv); e == nil {
		t.Fatal("changed operation input accepted")
	}
}

func TestUnknownExternalIsNotBlindlyRetried(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	snap := basicSnapshot("http://127.0.0.1")
	snap.Connectors = []Connector{{Name: "remote", Endpoint: "https://example.invalid/mcp", Protocol: "2025-11-25", Tools: []Tool{tool("write", "write fixture", `{"type":"object","additionalProperties":false}`)}}}
	submit(t, s, snap)
	r := claim(t, s, "one")
	inv := invocation(r)
	inv.Name = "mcp_remote_write"
	inv.Arguments = json.RawMessage(`{}`)
	var effects atomic.Int32
	execute := func(context.Context, Run) ([]byte, error) {
		effects.Add(1)
		return nil, errors.New("response lost after remote effect")
	}
	if _, e := s.ExternalTool(ctx, inv, execute); !errors.Is(e, ErrUnknown) {
		t.Fatal(e)
	}
	if _, e := s.ExternalTool(ctx, inv, execute); !errors.Is(e, ErrUnknown) {
		t.Fatal(e)
	}
	if effects.Load() != 1 {
		t.Fatal("unknown external effect repeated")
	}
	if e := s.Save(ctx, r, "waiting_unknown"); e != nil {
		t.Fatal(e)
	}
	if e := s.Resolve(ctx, r.ID, inv.OperationID, "completed", "remote audit receipt ABC", json.RawMessage(`{"receipt":"ABC"}`)); e != nil {
		t.Fatal(e)
	}
	r = claim(t, s, "two")
	inv.Owner = r.Owner
	inv.Fence = r.Fence
	result, e := s.ExternalTool(ctx, inv, execute)
	if e != nil || !strings.Contains(string(result), "ABC") || effects.Load() != 1 {
		t.Fatal("verified receipt not replayed", e)
	}
}

func TestCancellationAndChildSpawn(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	snap := basicSnapshot("http://127.0.0.1")
	snap.Children = map[string]Snapshot{"child": basicSnapshot("http://127.0.0.1")}
	parentID := submit(t, s, snap)
	r := claim(t, s, "one")
	inv := invocation(r)
	inv.Name = "spawn_agent"
	inv.Arguments = json.RawMessage(`{"agent_id":"child","task":"test child"}`)
	a, e := s.LocalTool(ctx, inv)
	if e != nil {
		t.Fatal(e)
	}
	b, e := s.LocalTool(ctx, inv)
	var first, second map[string]string
	_ = json.Unmarshal(a, &first)
	_ = json.Unmarshal(b, &second)
	var children int
	_ = s.DB.QueryRow(ctx, "SELECT count(*) FROM runs WHERE parent_id=$1", parentID).Scan(&children)
	if e != nil || first["child_run_id"] != second["child_run_id"] || children != 1 {
		t.Fatal("duplicate child spawn", e, children)
	}
	if e = s.Cancel(ctx, parentID); e != nil {
		t.Fatal(e)
	}
	if _, e = s.LocalTool(ctx, invocation(r)); !errors.Is(e, ErrFence) {
		t.Fatal("write after cancellation", e)
	}
	var uncancelled int
	s.DB.QueryRow(ctx, "SELECT count(*) FROM runs WHERE NOT cancel_requested").Scan(&uncancelled)
	if uncancelled != 0 {
		t.Fatal("child cancellation not propagated")
	}
}

func TestConstraintRevisionRejectsOldPlan(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	submit(t, s, basicSnapshot("http://127.0.0.1"))
	r := claim(t, s, "one")
	if e := s.Constraints(ctx, r.ID, []string{"new correction"}); e != nil {
		t.Fatal(e)
	}
	if _, e := s.LocalTool(ctx, invocation(r)); e == nil {
		t.Fatal("old plan ignored revised constraints")
	}
	if e := s.Save(ctx, r, "completed"); e == nil {
		t.Fatal("outdated final answer committed")
	}
	fresh, e := s.Run(ctx, r.ID)
	if e != nil || fresh.Constraints[0] != "new correction" {
		t.Fatal("constraint lost")
	}
}

func TestImmutableArtifactsAndGC(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	hash, e := s.PutArtifact(ctx, []byte("evidence"), "text/plain", "report:1")
	if e != nil {
		t.Fatal(e)
	}
	s.DB.Exec(ctx, "UPDATE artifacts SET created_at=now()-interval '48 hours'")
	if n, e := s.GC(ctx); e != nil || n != 0 {
		t.Fatal("referenced artifact deleted", e)
	}
	body, _, e := s.Artifact(ctx, hash)
	if e != nil || string(body) != "evidence" {
		t.Fatal(e)
	}
	s.DB.Exec(ctx, "DELETE FROM artifact_refs WHERE root='report:1'")
	if n, e := s.GC(ctx); e != nil || n != 1 {
		t.Fatal("unreferenced artifact not collected", e)
	}
}

func completion(w http.ResponseWriter, m Message) {
	jsonResponse(w, 200, map[string]any{"id": "fixture-response", "choices": []any{map[string]any{"message": m, "finish_reason": func() string {
		if len(m.ToolCalls) > 0 {
			return "tool_calls"
		}
		return "stop"
	}()}}, "usage": map[string]int{"total_tokens": 7}})
}
func TestLegacyRecoveryAfterToolCommitBeforeCheckpoint(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	var modelCalls atomic.Int32
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		modelCalls.Add(1)
		completion(w, Message{Role: "assistant", Content: "Fixture completed from stored receipt."})
	}))
	defer model.Close()
	snap := basicSnapshot(model.URL)
	submit(t, s, snap)
	r := claim(t, s, "old")
	_, _ = s.DB.Exec(ctx, "UPDATE runs SET engine='legacy-go' WHERE id=$1", r.ID)
	r.Engine = "legacy-go"
	tc := ToolCall{ID: "save", Type: "function", Function: FunctionCall{Name: "note_save", Arguments: string(invocation(r).Arguments)}}
	r.State.Messages = append(r.State.Messages, Message{Role: "assistant", ToolCalls: []ToolCall{tc}})
	r.Step = 1
	r.State.PlanRevision = r.RuleRevision
	if e := s.Save(ctx, r, "running"); e != nil {
		t.Fatal(e)
	}
	if _, e := s.LocalTool(ctx, invocation(r)); e != nil {
		t.Fatal(e)
	}
	s.DB.Exec(ctx, "UPDATE runs SET lease_until=now()-interval '1 second' WHERE id=$1", r.ID)
	r = claim(t, s, "new")
	hub := httptest.NewServer((&Server{Store: s, Role: "toolhub", Token: testToken}).Handler())
	defer hub.Close()
	worker := Worker{Store: s, ID: "new", Lease: 10 * time.Second, ToolHubURL: hub.URL, Token: testToken}
	worker.execute(ctx, r)
	done, e := s.Run(ctx, r.ID)
	if e != nil || done.Status != "completed" {
		t.Fatalf("resume failed %+v %v", done.State, e)
	}
	var docs int
	s.DB.QueryRow(ctx, "SELECT count(*) FROM documents").Scan(&docs)
	if docs != 1 || modelCalls.Load() != 1 {
		t.Fatal("recovery repeated committed work")
	}
}

func TestWorkerSubprocess(t *testing.T) {
	if os.Getenv("AGENTOS_WORKER_TEST") != "1" {
		return
	}
	s, e := Open(context.Background(), os.Getenv("TEST_DATABASE_URL"))
	if e != nil {
		t.Fatal(e)
	}
	defer s.DB.Close()
	worker := Worker{Store: s, ID: os.Getenv("TEST_WORKER_ID"), Lease: 1200 * time.Millisecond, Poll: 20 * time.Millisecond, ToolHubURL: os.Getenv("TEST_TOOLHUB_URL"), Token: testToken}
	_ = worker.Run(context.Background())
}
func startTestWorker(t *testing.T, dsn, hub, id string) *exec.Cmd {
	t.Helper()
	exe, e := os.Executable()
	if e != nil {
		t.Fatal(e)
	}
	cmd := exec.Command(exe, "-test.run=^TestWorkerSubprocess$")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = append(os.Environ(), "AGENTOS_WORKER_TEST=1", "TEST_DATABASE_URL="+dsn, "TEST_TOOLHUB_URL="+hub, "TEST_WORKER_ID="+id)
	if e = cmd.Start(); e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() {
		if cmd.ProcessState == nil {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
		}
	})
	return cmd
}
func TestRealProcessKillAndTakeover(t *testing.T) {
	s, dsn := testStore(t)
	var requests atomic.Int32
	started := make(chan struct{})
	releaseFirst := make(chan struct{})
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if requests.Add(1) == 1 {
			close(started)
			select {
			case <-r.Context().Done():
				return
			case <-releaseFirst:
				return
			}
		}
		completion(w, Message{Role: "assistant", Content: "Recovered by second process."})
	}))
	defer model.Close()
	defer close(releaseFirst)
	hub := httptest.NewServer((&Server{Store: s, Role: "toolhub", Token: testToken}).Handler())
	defer hub.Close()
	id := submit(t, s, basicSnapshot(model.URL))
	first := startTestWorker(t, dsn, hub.URL, "process-A")
	select {
	case <-started:
	case <-time.After(10 * time.Second):
		t.Fatal("first worker did not start model request")
	}
	second := startTestWorker(t, dsn, hub.URL, "process-B")
	_ = second
	if e := first.Process.Kill(); e != nil {
		t.Fatal(e)
	}
	_ = first.Wait()
	deadline := time.Now().Add(12 * time.Second)
	for time.Now().Before(deadline) {
		r, e := s.Run(context.Background(), id)
		if e != nil {
			t.Fatal(e)
		}
		if r.Status == "completed" {
			if r.Owner != "process-B" || r.Fence != 2 {
				t.Fatal("not taken over by second process")
			}
			var abandoned, completed int
			s.DB.QueryRow(context.Background(), "SELECT count(*) FILTER(WHERE status='abandoned'),count(*) FILTER(WHERE status='completed') FROM model_attempts").Scan(&abandoned, &completed)
			if abandoned != 1 || completed != 1 {
				t.Fatal("attempt accounting incorrect")
			}
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	last, _ := s.Run(context.Background(), id)
	t.Fatalf("replacement process did not recover task: %s %s", last.Status, last.State.Error)
}

func TestMCPHandshakeAndSSE(t *testing.T) {
	var initialized bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var rpc struct {
			Method string `json:"method"`
		}
		json.NewDecoder(r.Body).Decode(&rpc)
		switch rpc.Method {
		case "initialize":
			w.Header().Set("MCP-Session-Id", "fixture-session")
			jsonResponse(w, 200, map[string]any{"jsonrpc": "2.0", "id": 1, "result": map[string]any{"protocolVersion": "2025-11-25", "capabilities": map[string]any{}, "serverInfo": map[string]string{"name": "fixture", "version": "1"}}})
		case "notifications/initialized":
			initialized = true
			w.WriteHeader(202)
		case "tools/list":
			if !initialized || r.Header.Get("MCP-Session-Id") != "fixture-session" {
				t.Error("missing MCP handshake/session")
			}
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprint(w, "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"lookup\",\"description\":\"Fixture lookup\",\"inputSchema\":{\"type\":\"object\"}}]}}\n\n")
		}
	}))
	defer server.Close()
	tools, e := DiscoverMCP(context.Background(), Connector{Endpoint: server.URL, Protocol: "2025-11-25"})
	if e != nil || len(tools) != 1 || tools[0].Name != "lookup" {
		t.Fatal(tools, e)
	}
}
func TestSchemaRejectsExternalReferences(t *testing.T) {
	if _, e := compileSchema([]byte(`{"$ref":"https://example.invalid/schema"}`)); e == nil {
		t.Fatal("external schema reference accepted")
	}
	if e := validateArgs(Builtins[0], []byte(`{"query":"库存","unexpected":true}`)); e == nil {
		t.Fatal("unknown argument accepted")
	}
}
func TestLocalAuthenticationRejectsRebinding(t *testing.T) {
	s := &Server{Role: "control", DevLocal: true}
	h := s.auth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	for _, host := range []string{"evil.example", "127.0.0.1:8090"} {
		req := httptest.NewRequest("POST", "http://"+host+"/api/runs", strings.NewReader(`{}`))
		req.RemoteAddr = "127.0.0.1:5000"
		req.Header.Set("X-AgentOS-Client", "web")
		req.Header.Set("Origin", "https://evil.example")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		if w.Code != 401 {
			t.Fatal("cross-origin/rebinding request accepted")
		}
	}
}
