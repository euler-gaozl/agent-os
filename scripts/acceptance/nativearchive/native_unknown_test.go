//go:build darwin || linux

package nativearchive

import (
	"bytes"
	"context"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// This file shares only test helpers with native_archive_test.go. Independent
// Runtime/Worker/Storage binaries and the pinned Node runner do the actual work.
type unknownProcess struct {
	PID, PPID, PGID, UID int
	Started, Command     string
}

func unknownIdentity(ctx context.Context, pid int) (unknownProcess, bool, error) {
	var identity unknownProcess
	cmd := exec.CommandContext(ctx, "ps", "-p", strconv.Itoa(pid), "-o", "pid=,ppid=,pgid=,uid=,lstart=,command=")
	cmd.Env = cleanEnv()
	b, err := cmd.Output()
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) && exit.ExitCode() == 1 && len(bytes.TrimSpace(b)) == 0 {
			if killErr := syscall.Kill(pid, 0); killErr == syscall.ESRCH {
				return identity, false, nil
			}
			return identity, false, errors.New("ps failed without confirming fixture PID absence")
		}
		return identity, false, fmt.Errorf("inspect fixture process: %w", err)
	}
	f := strings.Fields(string(b))
	if len(f) < 10 {
		return identity, false, errors.New("invalid process identity output")
	}
	for i, ptr := range []*int{&identity.PID, &identity.PPID, &identity.PGID, &identity.UID} {
		*ptr, err = strconv.Atoi(f[i])
		if err != nil {
			return identity, false, errors.New("invalid numeric process identity")
		}
	}
	identity.Started, identity.Command = strings.Join(f[4:9], " "), strings.Join(f[9:], " ")
	if identity.PID != pid || identity.UID != os.Getuid() {
		return identity, false, errors.New("fixture process identity mismatch")
	}
	return identity, true, nil
}

func unknownNode(t *testing.T, ctx context.Context, worker unknownProcess, node, runner string) unknownProcess {
	t.Helper()
	// Inspect only PID/PPID globally; command lines are read solely for our
	// child's PIDs, never for unrelated platform services.
	cmd := exec.CommandContext(ctx, "ps", "-axo", "pid=,ppid=")
	cmd.Env = cleanEnv()
	b, err := cmd.Output()
	need(t, err)
	var children []int
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) != 2 {
			continue
		}
		parent, err := strconv.Atoi(f[1])
		if err == nil && parent == worker.PID {
			pid, err := strconv.Atoi(f[0])
			need(t, err)
			children = append(children, pid)
		}
	}
	if len(children) != 1 {
		t.Fatal("expected exactly one live Node child of the fixture Worker", len(children))
	}
	child, alive, err := unknownIdentity(ctx, children[0])
	need(t, err)
	want := node + " --max-old-space-size=512 --no-global-search-paths " + runner
	if !alive || child.PPID != worker.PID || child.PGID != worker.PGID || child.Command != want {
		t.Fatal("native Node identity does not match this Worker and pinned runner")
	}
	return child
}

func unknownWorkerStill(t *testing.T, ctx context.Context, before unknownProcess) {
	t.Helper()
	after, alive, err := unknownIdentity(ctx, before.PID)
	need(t, err)
	if !alive || before != after {
		t.Fatal("fixture Worker was replaced or exited")
	}
}

func unknownNodeGone(t *testing.T, ctx context.Context, worker, node unknownProcess) []string {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	var absent []string
	for {
		_, alive, err := unknownIdentity(ctx, node.PID)
		need(t, err)
		unknownWorkerStill(t, ctx, worker)
		if alive {
			absent = nil
		} else {
			absent = append(absent, time.Now().UTC().Format(time.RFC3339Nano))
			if len(absent) == 6 {
				return absent // six real observations spanning at least 500 ms
			}
		}
		if time.Now().After(deadline) {
			t.Fatal("native Node did not remain absent while Worker stayed alive")
		}
		select {
		case <-ctx.Done():
			t.Fatal("process exit observation timed out")
		case <-time.After(100 * time.Millisecond):
		}
	}
}

type unknownRun struct {
	ID, Status, Owner, Engine string
	Fence                     int64
	CancelRequested           bool `json:"cancel_requested"`
	State                     struct{ Result, Error string }
}

func unknownReadRun(t *testing.T, ctx context.Context, base, token, id string) unknownRun {
	t.Helper()
	var run unknownRun
	need(t, json.Unmarshal(ok(t, ctx, "GET", base+"/v1/runs/"+id, token, nil), &run))
	return run
}

func unknownWaitRun(t *testing.T, ctx context.Context, base, token, id, want string) unknownRun {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for {
		run := unknownReadRun(t, ctx, base, token, id)
		if run.Status == want {
			return run
		}
		if run.Status == "failed" || run.Status == "cancelled" || run.Status == "completed" || run.Status == "waiting_unknown" {
			t.Fatal("unexpected fixture task status", run.Status, "wanted", want)
		}
		if time.Now().After(deadline) {
			t.Fatal("fixture task status deadline", run.Status, "wanted", want)
		}
		select {
		case <-ctx.Done():
			t.Fatal("fixture task context deadline")
		case <-time.After(50 * time.Millisecond):
		}
	}
}

func unknownRows(t *testing.T, ctx context.Context, db *pgxpool.Pool, query, id string) []byte {
	t.Helper()
	var b []byte
	need(t, db.QueryRow(ctx, query, id).Scan(&b))
	return b
}

func unknownArchives(t *testing.T, ctx context.Context, runDB, storageDB *pgxpool.Pool, storageURL, token, id string) object {
	t.Helper()
	var pending int
	need(t, runDB.QueryRow(ctx, "SELECT count(*) FROM harness_archives WHERE run_id=$1 AND (batch IS NOT NULL OR manifest_hash='')", id).Scan(&pending))
	if pending != 0 {
		t.Fatal("external action crossed an unconfirmed archive barrier", pending)
	}
	rows, err := runDB.Query(ctx, "SELECT manifest_hash FROM harness_archives WHERE run_id=$1 ORDER BY seq", id)
	need(t, err)
	var hashes []string
	for rows.Next() {
		var h string
		need(t, rows.Scan(&h))
		hashes = append(hashes, h)
	}
	need(t, rows.Err())
	rows.Close()
	if len(hashes) == 0 {
		t.Fatal("native evidence archives missing")
	}
	previous, end, total := "", 0, 0
	for _, h := range hashes {
		m, b := readArchive(t, ctx, storageDB, storageURL, token, h, id)
		if m.Previous != previous || m.EventStart != end {
			t.Fatal("native archive chain is inconsistent")
		}
		previous, end, total = h, m.EventEnd, total+len(b)
	}
	return object{"manifests": hashes, "bytes": total, "all_manifest_and_part_run_refs_verified": true, "pending": pending}
}

func unknownUsage(t *testing.T, ctx context.Context, base, token, id string) []byte {
	t.Helper()
	b := ok(t, ctx, "GET", base+"/v1/runs/"+id+"/usage", token, nil)
	var u struct {
		Count        int `json:"attempts"`
		UnknownCount int `json:"unknown_usage_attempts"`
		Prompt       int `json:"prompt_tokens"`
		Completion   int `json:"completion_tokens"`
		Cached       int `json:"cached_prompt_tokens"`
		Accounted    int `json:"accounted_tokens"`
	}
	need(t, json.Unmarshal(b, &u))
	if u.Count != 1 || u.UnknownCount != 0 || u.Prompt != 1800 || u.Completion != 100 || u.Cached != 900 || u.Accounted != 1900 {
		t.Fatal("synthetic model usage changed or became unknown")
	}
	return b
}

func TestNativeUnknownExternalEffectCancellation(t *testing.T) {
	dir := os.Getenv("NATIVE_UNKNOWN_EVIDENCE")
	if dir == "" {
		t.Skip("explicit isolated native unknown-effect acceptance not configured")
	}
	if !filepath.IsAbs(dir) || filepath.Clean(dir) != dir || strings.ContainsAny(dir, "\r\n\t") {
		t.Fatal("new canonical absolute evidence directory required")
	}
	need(t, os.Mkdir(dir, 0700))
	// Leave room inside the caller's 3-minute Go timeout for the inherited
	// process-group and independent database/role cleanup hooks.
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	u, err := url.Parse(os.Getenv("TEST_DATABASE_URL"))
	need(t, err)
	if (u.Scheme != "postgres" && u.Scheme != "postgresql") || u.Host != "127.0.0.1:55432" || u.Path != "/postgres" || u.RawQuery != "sslmode=disable" || u.Fragment != "" || u.User == nil || u.User.Username() != "agentos_mac_test" {
		t.Fatal("requires the independent Mac loopback fixture administrator")
	}
	paths, hashes := map[string]string{}, map[string]string{}
	for _, key := range []string{"RUNTIME", "WORKER", "STORAGE", "RUNTIME_MIGRATOR", "STORAGE_MIGRATOR", "NODE", "RUNNER"} {
		p := os.Getenv("NATIVE_ARCHIVE_" + key)
		if !filepath.IsAbs(p) || strings.ContainsAny(p, "\r\n\t") {
			t.Fatal("absolute fixed artifact path required", key)
		}
		b, err := os.ReadFile(p)
		need(t, err)
		paths[key], hashes[key] = p, hash(b)
	}
	save(t, dir, "inputs.json", object{"os": runtime.GOOS, "arch": runtime.GOARCH, "go": runtime.Version(), "engine": engine, "paths": paths, "sha256": hashes, "real_provider_calls": 0})
	admin, err := pgxpool.New(ctx, u.String())
	need(t, err)
	t.Cleanup(admin.Close)
	suffix := nonce(t)[:12]
	prefix := "nu_" + suffix
	db := database(t, ctx, admin, u, dir, suffix, "runtime", paths["RUNTIME_MIGRATOR"], prefix+"_runtime", prefix+"_worker")
	storageDB := database(t, ctx, admin, u, dir, suffix, "storage", paths["STORAGE_MIGRATOR"], prefix+"_storage")
	tokens, peers := map[string]string{}, map[string]string{}
	for _, role := range []string{"runtime", "worker", "storage", "control", "toolhub"} {
		tokens[role] = nonce(t) + nonce(t)
		peers[role] = hash([]byte(tokens[role]))
	}
	fixtureNonce := nonce(t)
	unknownTask, healthTask := "native-unknown:"+fixtureNonce, "native-health:"+fixtureNonce
	var models, effects, routes, resolves atomic.Int64
	var healthyAllowed atomic.Bool
	var invMu sync.Mutex
	var invocation []byte
	var routeStatuses []int
	effectCommitted, dropReply, healthEntered, healthReply := make(chan []byte, 1), make(chan struct{}), make(chan struct{}, 1), make(chan struct{})
	var dropOnce, healthOnce sync.Once
	unblockEffect := func() { dropOnce.Do(func() { close(dropReply) }) }
	unblockHealth := func() { healthOnce.Do(func() { close(healthReply) }) }
	// Normal Fatal/return must unblock fixture handlers before server Close.
	defer unblockEffect()
	defer unblockHealth()
	effectPath := filepath.Join(dir, "effect-receipt.json")
	mcp := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var rpc struct {
			Method string `json:"method"`
			Params struct {
				Name      string `json:"name"`
				Arguments struct {
					Nonce string `json:"nonce"`
				} `json:"arguments"`
			} `json:"params"`
		}
		if r.Method != "POST" || json.NewDecoder(io.LimitReader(r.Body, (1<<20)+1)).Decode(&rpc) != nil {
			http.Error(w, "invalid MCP fixture request", 400)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		switch rpc.Method {
		case "initialize":
			_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25"}}`))
		case "notifications/initialized":
			w.WriteHeader(202)
		case "tools/call":
			if effects.Add(1) != 1 || rpc.Params.Name != "apply" || rpc.Params.Arguments.Nonce != fixtureNonce {
				t.Error("effectful MCP invocation repeated or input changed")
				http.Error(w, "unexpected effect request", 409)
				return
			}
			invMu.Lock()
			original := append([]byte(nil), invocation...)
			invMu.Unlock()
			var inv struct {
				RunID       string `json:"run_id"`
				OperationID string `json:"operation_id"`
				Name        string `json:"name"`
				Arguments   struct {
					Nonce string `json:"nonce"`
				} `json:"arguments"`
			}
			if json.Unmarshal(original, &inv) != nil || inv.Name != "mcp_effect_apply" || inv.Arguments.Nonce != fixtureNonce || !strings.HasPrefix(inv.OperationID, inv.RunID+"/") || len(inv.RunID) != 32 {
				t.Error("effect has no matching staged Runtime invocation")
				http.Error(w, "unbound effect", 400)
				return
			}
			receipt := object{"isError": false, "content": []any{object{"type": "text", "text": "synthetic effect committed: " + fixtureNonce}}}
			durable := raw(object{"version": 1, "nonce": fixtureNonce, "run_id": inv.RunID, "operation_id": inv.OperationID, "invocation_sha256": hash(original), "receipt": receipt})
			file, err := os.OpenFile(effectPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
			if err == nil {
				_, err = file.Write(durable)
				if err == nil {
					err = file.Sync()
				}
				closeErr := file.Close()
				if err == nil {
					err = closeErr
				}
			}
			if err == nil {
				parent, openErr := os.Open(dir)
				err = openErr
				if err == nil {
					err = parent.Sync()
					closeErr := parent.Close()
					if err == nil {
						err = closeErr
					}
				}
			}
			if err != nil {
				t.Error("durable synthetic effect write failed", err)
				http.Error(w, "effect persistence failure", 500)
				return
			}
			effectCommitted <- durable
			select {
			case <-dropReply:
			case <-r.Context().Done():
			}
			// Do not fabricate an HTTP failure response: close the real accepted
			// TCP connection after fsync, before sending any response headers.
			hijacker, ok := w.(http.Hijacker)
			if !ok {
				t.Error("MCP fixture cannot hijack connection")
				return
			}
			conn, _, err := hijacker.Hijack()
			if err != nil {
				t.Error("MCP fixture hijack failed", err)
				return
			}
			_ = conn.Close()
		default:
			http.Error(w, "unexpected MCP method", 400)
		}
	}))
	t.Cleanup(mcp.Close)
	final := "Synthetic health task completed after explicit reconciliation."
	model := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, err := io.ReadAll(io.LimitReader(r.Body, (8<<20)+1))
		var in struct {
			Max      int               `json:"max_tokens"`
			Messages []json.RawMessage `json:"messages"`
		}
		if err != nil || len(b) > 8<<20 || json.Unmarshal(b, &in) != nil || in.Max != 393216 || len(in.Messages) == 0 {
			t.Error("native model request shape changed")
			http.Error(w, "invalid fixture request", 400)
			return
		}
		n := models.Add(1)
		message, finish := object{"role": "assistant", "content": final}, "stop"
		if n == 1 && bytes.Contains(b, []byte(unknownTask)) {
			message["content"] = "Apply the supplied synthetic effect once."
			message["tool_calls"] = []any{object{"id": "synthetic-effect-1", "type": "function", "function": object{"name": "mcp_effect_apply", "arguments": string(raw(object{"nonce": fixtureNonce}))}}}
			finish = "tool_calls"
		} else if n == 2 && healthyAllowed.Load() && bytes.Contains(b, []byte(healthTask)) {
			healthEntered <- struct{}{}
			select {
			case <-healthReply:
			case <-r.Context().Done():
				return
			}
		} else {
			t.Error("unexpected or repeated synthetic model request", n)
			http.Error(w, "unplanned model request", 500)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(raw(object{"choices": []any{object{"message": message, "finish_reason": finish}}, "usage": object{"prompt_tokens": 1800, "completion_tokens": 100, "prompt_cache_hit_tokens": 900, "total_tokens": 1900}}))
	}))
	t.Cleanup(model.Close)
	ca := filepath.Join(dir, "fixture-ca.pem")
	need(t, os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: model.Certificate().Raw}), 0600))
	agent := object{"name": "Synthetic native unknown-effect fixture", "prompt": "Use only supplied synthetic inputs. Do not retry an effect without a receipt.", "tools": []string{}, "connectors": []any{object{"id": "effect", "revision": 1}}, "model": object{"base_url": model.URL, "model": "native-fixture", "max_tokens": 393216, "limits": object{"model": "native-fixture", "base_url": model.URL, "protocol": "openai-chat-completions", "context_window": 1048576, "max_output_tokens": 393216, "source": model.URL + "/models", "observed_at": "2026-10-15T00:00:00Z", "metadata_sha256": strings.Repeat("a", 64)}}, "max_steps": 4, "max_model_attempts": 2, "context_tokens": 1048576, "context_bytes": 64000, "max_children": 0}
	connector := object{"name": "effect", "endpoint": mcp.URL, "protocol": "2025-11-25", "read_only": false, "tools": []any{object{"name": "apply", "description": "Persist exactly the supplied synthetic nonce.", "inputSchema": object{"type": "object", "properties": object{"nonce": object{"type": "string", "minLength": 32, "maxLength": 32}}, "required": []string{"nonce"}, "additionalProperties": false}}}}
	registry := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v1/resources/agent/fixture/1":
			_, _ = w.Write(raw(object{"kind": "agent", "id": "fixture", "revision": 1, "spec": agent}))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(registry.Close)
	runtimeURL, storageURL := "http://"+address(t), "http://"+address(t)
	hub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Connector/skill resolution belongs to ToolHub's catalog, not Registry.
		// Preserve its separate GET permission for Runtime/Worker identities.
		if r.Method == "GET" && r.URL.Path == "/v1/resolve/connector/effect/1" {
			auth := r.Header.Get("Authorization")
			if auth != "Bearer "+tokens["runtime"] && auth != "Bearer "+tokens["worker"] {
				http.Error(w, "fixture catalog caller rejected", 403)
				return
			}
			resolves.Add(1)
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(raw(object{"kind": "connector", "id": "effect", "revision": 1, "spec": connector}))
			return
		}
		if r.Method != "POST" || r.URL.Path != "/invoke" || r.Header.Get("Authorization") != "Bearer "+tokens["worker"] {
			http.Error(w, "fixture caller rejected", 403)
			return
		}
		b, err := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
		if err != nil || len(b) > 1<<20 {
			http.Error(w, "invalid fixture invocation", 400)
			return
		}
		routes.Add(1)
		invMu.Lock()
		invocation = append([]byte(nil), b...)
		invMu.Unlock()
		out, status, err := request(r.Context(), "POST", runtimeURL+"/invoke", tokens["toolhub"], b)
		if err != nil {
			http.Error(w, "fixture Runtime transport failure", 502)
			return
		}
		invMu.Lock()
		routeStatuses = append(routeStatuses, status)
		invMu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status) // preserve the real ErrUnknown HTTP 409
		_, _ = w.Write(out)
	}))
	t.Cleanup(hub.Close)
	base := map[string]string{"SERVICE_PEERS": string(raw(peers)), "REGISTRY_URL": registry.URL, "TOOLHUB_URL": hub.URL, "RUNTIME_URL": runtimeURL, "STORAGE_URL": storageURL, "SANDBOX_URL": registry.URL, "KNOWLEDGE_URL": registry.URL, "DB_MAX_CONNS": "3", "GOMEMLIMIT": "96MiB"}
	conf := func(role, name, listen, dsn string) map[string]string {
		c := map[string]string{}
		for key, value := range base {
			c[key] = value
		}
		c["SERVICE_TOKEN"], c["INSTANCE_ID"], c["LISTEN"], c["DATABASE_URL"] = tokens[role], name, listen, dsn
		return c
	}
	rc := conf("runtime", "unknown-runtime", strings.TrimPrefix(runtimeURL, "http://"), db.dsns[prefix+"_runtime"])
	rc["DEFAULT_RUN_ENGINE"], rc["MCP_ALLOWED_HOSTS"] = engine, strings.TrimPrefix(mcp.URL, "http://")
	runtimeChild := start(t, ctx, dir, "runtime", paths["RUNTIME"], rc)
	sc := conf("storage", "unknown-storage", strings.TrimPrefix(storageURL, "http://"), storageDB.dsns[prefix+"_storage"])
	storageChild := start(t, ctx, dir, "storage", paths["STORAGE"], sc)
	ready(t, ctx, runtimeURL, tokens["control"])
	ready(t, ctx, storageURL, tokens["control"])
	wc := conf("worker", "unknown-worker", address(t), db.dsns[prefix+"_worker"])
	wc["AGENTOS_NODE"], wc["DSH_NATIVE_RUNNER"], wc["SSL_CERT_FILE"], wc["GODEBUG"], wc["GOMEMLIMIT"] = paths["NODE"], paths["RUNNER"], ca, "x509sslcertoverrideplatform=1", "192MiB"
	workerChild := start(t, ctx, dir, "worker", paths["WORKER"], wc)
	ready(t, ctx, "http://"+wc["LISTEN"], tokens["worker"])
	identities := map[string]unknownProcess{}
	for name, p := range map[string]*child{"runtime": runtimeChild, "storage": storageChild, "worker": workerChild} {
		identity, alive, err := unknownIdentity(ctx, p.cmd.Process.Pid)
		need(t, err)
		if !alive || identity.PGID != identity.PID || identity.PPID != os.Getpid() || identity.Command != strings.Join(p.cmd.Args, " ") {
			t.Fatal("fixture service process identity mismatch", name)
		}
		identities[name] = identity
	}
	workerIdentity := identities["worker"]
	var submitted struct{ ID string }
	need(t, json.Unmarshal(ok(t, ctx, "POST", runtimeURL+"/v1/runs", tokens["control"], object{"agent": object{"id": "fixture", "revision": 1}, "task": unknownTask}), &submitted))
	if len(submitted.ID) != 32 {
		t.Fatal("new unknown-effect task id missing")
	}
	var effect []byte
	select {
	case effect = <-effectCommitted:
	case <-ctx.Done():
		t.Fatal("durable effect not reached")
	case <-workerChild.done:
		t.Fatal("Worker exited before durable effect")
	}
	originalNode := unknownNode(t, ctx, workerIdentity, paths["NODE"], paths["RUNNER"])
	identities["original_node"] = originalNode
	save(t, dir, "process-identities.json", identities)
	var durable struct {
		RunID         string          `json:"run_id"`
		OperationID   string          `json:"operation_id"`
		Nonce         string          `json:"nonce"`
		InvocationSHA string          `json:"invocation_sha256"`
		Receipt       json.RawMessage `json:"receipt"`
	}
	need(t, json.Unmarshal(effect, &durable))
	readEffect, err := os.ReadFile(effectPath)
	need(t, err)
	if durable.RunID != submitted.ID || durable.Nonce != fixtureNonce || !bytes.Equal(effect, readEffect) || len(durable.Receipt) == 0 {
		t.Fatal("fsynced effect identity or independent readback mismatch")
	}
	var callStatus string
	need(t, db.pool.QueryRow(ctx, "SELECT status FROM calls WHERE id=$1 AND run_id=$2 AND kind='tool'", durable.OperationID, submitted.ID).Scan(&callStatus))
	if callStatus != "inflight" || effects.Load() != 1 || models.Load() != 1 || routes.Load() != 1 {
		t.Fatal("effect did not follow one committed tool intent and model receipt")
	}
	if resolves.Load() != 2 {
		t.Fatal("connector catalog resolution did not cover frozen submission and tool governance", resolves.Load())
	}
	archiveBefore := unknownArchives(t, ctx, db.pool, storageDB.pool, storageURL, tokens["control"], submitted.ID)
	need(t, db.pool.QueryRow(ctx, "SELECT status FROM calls WHERE id=$1 AND run_id=$2", durable.OperationID, submitted.ID).Scan(&callStatus))
	invMu.Lock()
	prematureReply := len(routeStatuses) != 0
	invMu.Unlock()
	if callStatus != "inflight" || prematureReply {
		t.Fatal("MCP request ended before the intentional TCP disconnect")
	}
	var frozenReadOnly, frozenEndpoint string
	need(t, db.pool.QueryRow(ctx, "SELECT snapshot#>>'{connectors,0,read_only}',snapshot#>>'{connectors,0,endpoint}' FROM runs WHERE id=$1", submitted.ID).Scan(&frozenReadOnly, &frozenEndpoint))
	if frozenReadOnly != "false" || frozenEndpoint != mcp.URL {
		t.Fatal("new task did not freeze the effectful local connector")
	}
	save(t, dir, "effect-before-disconnect.json", object{"run_id": submitted.ID, "operation_id": durable.OperationID, "effect_sha256": hash(effect), "tool_status": callStatus, "archives": archiveBefore, "file_and_parent_fsynced": true, "model_requests": models.Load(), "effects": effects.Load()})
	unblockEffect()
	waiting := unknownWaitRun(t, ctx, runtimeURL, tokens["control"], submitted.ID, "waiting_unknown")
	if waiting.Engine != engine || waiting.CancelRequested || waiting.Fence != 1 {
		t.Fatal("unknown task changed frozen execution identity")
	}
	absentOriginal := unknownNodeGone(t, ctx, workerIdentity, originalNode)
	invMu.Lock()
	statuses := append([]int(nil), routeStatuses...)
	originalInvocation := append([]byte(nil), invocation...)
	invMu.Unlock()
	if len(statuses) != 1 || statuses[0] != http.StatusConflict || hash(originalInvocation) != durable.InvocationSHA {
		t.Fatal("ToolHub fixture did not preserve the original Runtime 409")
	}
	need(t, db.pool.QueryRow(ctx, "SELECT status FROM calls WHERE id=$1 AND run_id=$2 AND kind='tool'", durable.OperationID, submitted.ID).Scan(&callStatus))
	if callStatus != "unknown" {
		t.Fatal("effectful transport failure was not retained as unknown")
	}
	toolStableQuery := "SELECT to_jsonb(c)-'status'-'response'-'updated_at' FROM calls c WHERE id=$1 AND kind='tool'"
	toolBefore := unknownRows(t, ctx, db.pool, toolStableQuery, durable.OperationID)
	usageBefore := unknownUsage(t, ctx, runtimeURL, tokens["control"], submitted.ID)
	modelQuery := "SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.id),'[]'::jsonb) FROM calls c WHERE run_id=$1 AND kind='model'"
	attemptQuery := "SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.id),'[]'::jsonb) FROM model_attempts a JOIN calls c ON c.id=a.call_id WHERE c.run_id=$1"
	exchangeQuery := "SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.seq),'[]'::jsonb) FROM harness_exchanges e WHERE run_id=$1"
	modelBefore := unknownRows(t, ctx, db.pool, modelQuery, submitted.ID)
	attemptBefore := unknownRows(t, ctx, db.pool, attemptQuery, submitted.ID)
	exchangeBefore := unknownRows(t, ctx, db.pool, exchangeQuery, submitted.ID)
	var unresolvedExchange int
	need(t, db.pool.QueryRow(ctx, "SELECT count(*) FROM harness_exchanges WHERE run_id=$1 AND method='tool' AND response IS NULL", submitted.ID).Scan(&unresolvedExchange))
	if unresolvedExchange != 1 {
		t.Fatal("tool Exchange was incorrectly completed without its reply", unresolvedExchange)
	}
	ok(t, ctx, "POST", runtimeURL+"/v1/runs/"+submitted.ID+"/cancel", tokens["control"], object{})
	for i := 0; i < 4; i++ {
		run := unknownReadRun(t, ctx, runtimeURL, tokens["control"], submitted.ID)
		if run.Status != "waiting_unknown" || !run.CancelRequested || models.Load() != 1 || effects.Load() != 1 || routes.Load() != 1 {
			t.Fatal("cancel hid an unknown external effect or repeated execution")
		}
		time.Sleep(100 * time.Millisecond)
	}
	// Explicit controlled operator step: independently read durable receipt and
	// compare it to the real call identity before resolving through control API.
	verified, err := os.ReadFile(effectPath)
	need(t, err)
	var toolRequest []byte
	need(t, db.pool.QueryRow(ctx, "SELECT request FROM calls WHERE id=$1 AND run_id=$2 AND kind='tool' AND status='unknown'", durable.OperationID, submitted.ID).Scan(&toolRequest))
	var stored, invoked any
	need(t, json.Unmarshal(toolRequest, &stored))
	need(t, json.Unmarshal(originalInvocation, &invoked))
	if !bytes.Equal(effect, verified) || !bytes.Equal(raw(stored), raw(invoked)) {
		t.Fatal("operator receipt verification failed")
	}
	save(t, dir, "before-reconcile.json", object{"run_id": submitted.ID, "operation_id": durable.OperationID, "status": "waiting_unknown", "cancel_requested": true, "receipt_file_sha256": hash(verified), "invocation_matches_database": true, "usage": json.RawMessage(usageBefore), "tool_preserved_fields_sha256": hash(toolBefore), "model_calls_sha256": hash(modelBefore), "model_attempts_sha256": hash(attemptBefore), "exchanges_sha256": hash(exchangeBefore), "original_node_absent_observations": absentOriginal, "tool_exchange_unanswered": unresolvedExchange})
	reconcileEvidence := "Controlled synthetic operator verified fsynced effect-receipt.json sha256=" + hash(verified) + " and exact Runtime invocation"
	ok(t, ctx, "POST", runtimeURL+"/v1/runs/"+submitted.ID+"/reconcile", tokens["control"], object{"call_id": durable.OperationID, "decision": "completed", "evidence": reconcileEvidence, "result": json.RawMessage(durable.Receipt)})
	resolved := unknownWaitRun(t, ctx, runtimeURL, tokens["control"], submitted.ID, "cancelled")
	if !resolved.CancelRequested || resolved.Owner != "" || resolved.Fence != waiting.Fence || resolved.State.Result != "" {
		t.Fatal("reconciled cancelled task gained a false final result or changed fence")
	}
	var toolReceipt []byte
	need(t, db.pool.QueryRow(ctx, "SELECT status,response FROM calls WHERE id=$1 AND run_id=$2", durable.OperationID, submitted.ID).Scan(&callStatus, &toolReceipt))
	var actualReceipt, verifiedReceipt any
	need(t, json.Unmarshal(toolReceipt, &actualReceipt))
	need(t, json.Unmarshal(durable.Receipt, &verifiedReceipt))
	if callStatus != "completed" || !bytes.Equal(raw(actualReceipt), raw(verifiedReceipt)) {
		t.Fatal("reconciliation did not save the verified synthetic receipt")
	}
	healthyAllowed.Store(true)
	var healthy struct{ ID string }
	need(t, json.Unmarshal(ok(t, ctx, "POST", runtimeURL+"/v1/runs", tokens["control"], object{"agent": object{"id": "fixture", "revision": 1}, "task": healthTask}), &healthy))
	if len(healthy.ID) != 32 || healthy.ID == submitted.ID {
		t.Fatal("health task was not a distinct new run")
	}
	select {
	case <-healthEntered:
	case <-ctx.Done():
		t.Fatal("same Worker did not reach health model")
	case <-workerChild.done:
		t.Fatal("Worker exited before health task")
	}
	unknownWorkerStill(t, ctx, workerIdentity)
	healthNode := unknownNode(t, ctx, workerIdentity, paths["NODE"], paths["RUNNER"])
	if healthNode.PID == originalNode.PID {
		t.Fatal("health task unexpectedly reused the original Node PID")
	}
	identities["health_node"] = healthNode
	save(t, dir, "process-identities.json", identities)
	unblockHealth()
	health := unknownWaitRun(t, ctx, runtimeURL, tokens["control"], healthy.ID, "completed")
	if health.Engine != engine || health.Owner != "unknown-worker" || health.Fence != 1 || health.State.Result != final {
		t.Fatal("same Worker health task did not complete normally")
	}
	absentHealth := unknownNodeGone(t, ctx, workerIdentity, healthNode)
	absentOriginalAfter := unknownNodeGone(t, ctx, workerIdentity, originalNode)
	if models.Load() != 2 || effects.Load() != 1 || routes.Load() != 1 {
		t.Fatal("unknown-effect recovery duplicated model or tool execution")
	}
	if resolves.Load() != 3 {
		t.Fatal("unexpected connector catalog resolution count after the new health task", resolves.Load())
	}
	usageAfter := unknownUsage(t, ctx, runtimeURL, tokens["control"], submitted.ID)
	healthUsage := unknownUsage(t, ctx, runtimeURL, tokens["control"], healthy.ID)
	if !bytes.Equal(usageBefore, usageAfter) || !bytes.Equal(modelBefore, unknownRows(t, ctx, db.pool, modelQuery, submitted.ID)) || !bytes.Equal(attemptBefore, unknownRows(t, ctx, db.pool, attemptQuery, submitted.ID)) || !bytes.Equal(exchangeBefore, unknownRows(t, ctx, db.pool, exchangeQuery, submitted.ID)) {
		t.Fatal("cancel/reconcile/health task changed original model receipt, usage or native exchange")
	}
	if !bytes.Equal(toolBefore, unknownRows(t, ctx, db.pool, toolStableQuery, durable.OperationID)) {
		t.Fatal("reconciliation changed original tool request, error, fence, attempt or identity")
	}
	auditRows := unknownRows(t, ctx, db.pool, "SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.seq),'[]'::jsonb) FROM events e WHERE run_id=$1 AND kind='reconciled'", submitted.ID)
	var audits []struct {
		Payload struct {
			CallID   string `json:"call_id"`
			Decision string `json:"decision"`
			Evidence string `json:"evidence"`
		} `json:"payload"`
	}
	need(t, json.Unmarshal(auditRows, &audits))
	if len(audits) != 1 || audits[0].Payload.CallID != durable.OperationID || audits[0].Payload.Decision != "completed" || audits[0].Payload.Evidence != reconcileEvidence {
		t.Fatal("reconciliation audit did not bind exactly one decision to the verified receipt and tool operation")
	}
	save(t, dir, "reconcile-audit.json", json.RawMessage(auditRows))
	archiveAfter := unknownArchives(t, ctx, db.pool, storageDB.pool, storageURL, tokens["control"], submitted.ID)
	if !bytes.Equal(raw(archiveBefore), raw(archiveAfter)) {
		t.Fatal("original native archive or retention references changed")
	}
	healthArchives := unknownArchives(t, ctx, db.pool, storageDB.pool, storageURL, tokens["control"], healthy.ID)
	verified, err = os.ReadFile(effectPath)
	need(t, err)
	if !bytes.Equal(effect, verified) {
		t.Fatal("durable external receipt changed")
	}
	finalOriginal := unknownReadRun(t, ctx, runtimeURL, tokens["control"], submitted.ID)
	if finalOriginal.Status != "cancelled" || !finalOriginal.CancelRequested || finalOriginal.State.Result != "" {
		t.Fatal("original cancelled task was resumed implicitly")
	}
	save(t, dir, "usage-original.json", json.RawMessage(usageAfter))
	save(t, dir, "usage-health.json", json.RawMessage(healthUsage))
	save(t, dir, "catalog-resolution.json", object{"connector": "effect", "revision": 1, "endpoint": "/v1/resolve/connector/effect/1", "resolved": resolves.Load(), "expected_stages": []string{"unknown submission snapshot", "tool invocation governance", "health submission snapshot"}, "separate_from_effect_routes": true})
	save(t, dir, "reconcile-preservation.json", object{"tool_preserved_fields_sha256": hash(toolBefore), "request_error_fence_attempt_identity_unchanged": true, "reconciled_event_count": len(audits), "reconciled_event_sha256": hash(auditRows), "verified_effect_receipt_sha256": hash(effect), "decision": "completed", "operation_id": durable.OperationID})
	save(t, dir, "result.json", object{"passed": true, "run_id": submitted.ID, "health_run_id": healthy.ID, "engine": engine, "original_status": finalOriginal.Status, "tool_status": callStatus, "effects": effects.Load(), "tool_routes": routes.Load(), "model_requests": models.Load(), "real_provider_calls": 0, "unknown_model_usage_attempts": 0, "synthetic_accounted_tokens_per_run": 1900, "cost_estimate": nil, "effect_receipt_sha256": hash(effect), "runtime_tool_http_status": statuses[0], "same_worker_identity": workerIdentity, "original_node_absent_before_cancel": absentOriginal, "original_node_absent_after_health": absentOriginalAfter, "health_node_absent": absentHealth, "original_archives": archiveAfter, "health_archives": healthArchives, "original_model_and_exchange_rows_unchanged": true, "original_tool_exchange_response_remains_null": true, "sql_mutated_runtime_state": false, "scope": "real isolated Mac service binaries, Node, Storage, PostgreSQL and fsynced synthetic MCP effect; controlled explicit operator reconciliation, no real model, no automatic unknown-effect resolution, no Windows or full resource acceptance"})
	t.Logf("native-v4 external effect unknown/cancel/reconcile: effects=1 models=2 original=cancelled health=completed Worker PID=%d; both Node children stably exited", workerIdentity.PID)
}
