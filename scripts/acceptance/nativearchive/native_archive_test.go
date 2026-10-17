//go:build darwin || linux

// Package nativearchive tests independent service binaries over their public
// HTTP contracts. It imports no service implementation. Model/Registry/ToolHub
// routing are fixtures; Runtime, Worker, Node, Storage and PostgreSQL are real.
package nativearchive

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type object = map[string]any

const engine = "dsh-source-639ed015-native-v4"

func raw(v any) []byte {
	b, e := json.Marshal(v)
	if e != nil {
		panic(e)
	}
	return b
}
func hash(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func need(t *testing.T, e error) {
	t.Helper()
	if e != nil {
		t.Fatal(e)
	}
}
func nonce(t *testing.T) string {
	t.Helper()
	b := make([]byte, 16)
	_, e := rand.Read(b)
	need(t, e)
	return hex.EncodeToString(b)
}
func save(t *testing.T, dir, name string, v any) {
	t.Helper()
	need(t, os.WriteFile(filepath.Join(dir, name), raw(v), 0600))
}
func address(t *testing.T) string {
	t.Helper()
	l, e := net.Listen("tcp", "127.0.0.1:0")
	need(t, e)
	a := l.Addr().String()
	need(t, l.Close())
	return a
}

func cleanEnv() []string {
	// Never inherit provider keys, proxy settings, database/service credentials,
	// NODE_OPTIONS, or the surrounding developer's application configuration.
	e := []string{"LANG=C", "LC_ALL=C"}
	for _, k := range []string{"PATH", "TMPDIR"} {
		if v := os.Getenv(k); v != "" {
			e = append(e, k+"="+v)
		}
	}
	return e
}

func request(ctx context.Context, method, endpoint, token string, body []byte) ([]byte, int, error) {
	r, e := http.NewRequestWithContext(ctx, method, endpoint, bytes.NewReader(body))
	if e != nil {
		return nil, 0, e
	}
	r.Header.Set("Authorization", "Bearer "+token)
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Idempotency-Key", hash(append([]byte(endpoint), body...)))
	c := http.Client{Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return fmt.Errorf("redirect refused") }}
	res, e := c.Do(r)
	if e != nil {
		return nil, 0, e
	}
	defer res.Body.Close()
	b, e := io.ReadAll(io.LimitReader(res.Body, 8<<20))
	return b, res.StatusCode, e
}
func ok(t *testing.T, ctx context.Context, method, endpoint, token string, body any) []byte {
	t.Helper()
	var b []byte
	if body != nil {
		b = raw(body)
	}
	out, status, e := request(ctx, method, endpoint, token, b)
	need(t, e)
	if status != 200 && status != 201 && status != 202 {
		t.Fatalf("fixture HTTP %d at %s: %.200s", status, strings.Split(endpoint, "?")[0], out)
	}
	return out
}
func ready(t *testing.T, ctx context.Context, endpoint, token string) {
	t.Helper()
	for until := time.Now().Add(15 * time.Second); time.Now().Before(until); {
		_, status, e := request(ctx, "GET", endpoint+"/readyz", token, nil)
		if e == nil && status == 200 {
			return
		}
		time.Sleep(75 * time.Millisecond)
	}
	t.Fatal("fixture service readiness timeout", endpoint)
}

type child struct {
	cmd  *exec.Cmd
	done chan struct{}
	once sync.Once
	log  *os.File
}

func (p *child) stop(t *testing.T) {
	t.Helper()
	p.once.Do(func() {
		// Every child starts a new process group. This only kills that group's
		// Worker/Node tree, never a platform instance discovered by name or port.
		e := syscall.Kill(-p.cmd.Process.Pid, syscall.SIGKILL)
		if e != nil && e != syscall.ESRCH {
			t.Error("fixture group stop", e)
		}
		select {
		case <-p.done:
		case <-time.After(8 * time.Second):
			t.Error("fixture child wait timed out")
		}
		_ = p.log.Close()
	})
}
func start(t *testing.T, ctx context.Context, dir, name, binary string, config map[string]string) *child {
	t.Helper()
	file := filepath.Join(dir, name+".config.json")
	save(t, dir, name+".config.json", config)
	log, e := os.OpenFile(filepath.Join(dir, name+".log"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	need(t, e)
	c := exec.CommandContext(ctx, binary, "--config", file)
	c.Dir = dir
	c.Env = cleanEnv()
	c.Stdout = log
	c.Stderr = log
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	need(t, c.Start())
	p := &child{cmd: c, done: make(chan struct{}), log: log}
	go func() { _ = c.Wait(); close(p.done) }()
	t.Cleanup(func() {
		p.stop(t)
		if e := os.Remove(file); e != nil {
			t.Error("remove disposable config", e)
		}
	})
	return p
}

type fixtureDB struct {
	pool  *pgxpool.Pool
	dsns  map[string]string
	name  string
	roles []string
}

func database(t *testing.T, ctx context.Context, admin *pgxpool.Pool, adminURL *url.URL, dir, suffix, kind, migrator string, roles ...string) fixtureDB {
	t.Helper()
	name := "native_archive_" + suffix + "_" + kind
	f := fixtureDB{dsns: map[string]string{}, name: name, roles: roles}
	created := []string{}
	madeDB := false
	// Registered before any mutation so a partial setup still cleans its own
	// resources. Service cleanups register later and therefore run first.
	t.Cleanup(func() {
		if f.pool != nil {
			f.pool.Close()
		}
		c, done := context.WithTimeout(context.Background(), 20*time.Second)
		defer done()
		if madeDB {
			_, e := admin.Exec(c, "DROP DATABASE "+pgx.Identifier{name}.Sanitize()+" WITH (FORCE)")
			if e != nil {
				t.Error("drop isolated database", e)
			}
		}
		for _, r := range created {
			_, e := admin.Exec(c, "DROP ROLE "+pgx.Identifier{r}.Sanitize())
			if e != nil {
				t.Error("drop isolated role", e)
			}
		}
	})
	u := *adminURL
	u.Path = "/" + name
	for _, r := range roles {
		pass := nonce(t)
		_, e := admin.Exec(ctx, "CREATE ROLE "+pgx.Identifier{r}.Sanitize()+" LOGIN PASSWORD '"+pass+"'")
		need(t, e)
		created = append(created, r)
		a := u
		a.User = url.UserPassword(r, pass)
		f.dsns[r] = a.String()
	}
	_, e := admin.Exec(ctx, "CREATE DATABASE "+pgx.Identifier{name}.Sanitize()+" TEMPLATE template0")
	need(t, e)
	madeDB = true
	c := exec.CommandContext(ctx, migrator, "--role", roles[0])
	if len(roles) > 1 {
		c.Args = append(c.Args, "--worker-role", roles[1])
	}
	c.Env = append(cleanEnv(), "MIGRATION_DATABASE_URL="+u.String())
	out, e := c.CombinedOutput()
	if e != nil {
		t.Fatalf("%s Owner migration failed: %.400s", kind, out)
	}
	f.pool, e = pgxpool.New(ctx, u.String())
	need(t, e)
	save(t, dir, kind+"-database.json", object{"database": name, "roles": roles, "owner_migrator": filepath.Base(migrator), "created": true})
	return f
}

type manifest struct {
	Version     int    `json:"version"`
	RunID       string `json:"run_id"`
	Exchange    int    `json:"exchange"`
	EventStart  int    `json:"event_start"`
	EventEnd    int    `json:"event_end"`
	Bytes       int    `json:"bytes"`
	SHA256      string `json:"sha256"`
	Previous    string `json:"previous_manifest"`
	SourceOwner string `json:"source_owner"`
	SourceFence int64  `json:"source_fence"`
	Parts       []struct {
		Hash   string `json:"hash"`
		Offset int    `json:"offset_bytes"`
		Bytes  int    `json:"bytes"`
	} `json:"parts"`
}

func readArchive(t *testing.T, ctx context.Context, db *pgxpool.Pool, base, token, h, runID string) (manifest, []byte) {
	t.Helper()
	body := ok(t, ctx, "GET", base+"/artifacts/"+h, token, nil)
	if hash(body) != h {
		t.Fatal("manifest bytes changed")
	}
	var m manifest
	need(t, json.Unmarshal(body, &m))
	if m.Version != 1 || m.RunID != runID || len(m.Parts) == 0 || len(m.Parts) > 66 || m.Bytes > 64<<20 {
		t.Fatal("manifest contract mismatch")
	}
	var all []byte
	for _, p := range m.Parts {
		b := ok(t, ctx, "GET", base+"/artifacts/"+p.Hash, token, nil)
		if hash(b) != p.Hash || len(b) != p.Bytes || p.Offset != len(all) {
			t.Fatal("part hash/size/offset mismatch")
		}
		all = append(all, b...)
	}
	if len(all) != m.Bytes || hash(all) != m.SHA256 || !json.Valid(all) {
		t.Fatal("archive reconstruction mismatch")
	}
	// The administrative download API can read unreferenced objects, so bytes
	// alone do not prove retention. Both the manifest and every unique part
	// must have the exact run root used by the fixed execution protocol.
	unique := map[string]bool{h: true}
	for _, part := range m.Parts {
		unique[part.Hash] = true
	}
	hashes := make([]string, 0, len(unique))
	for retained := range unique {
		hashes = append(hashes, retained)
	}
	var references int
	need(t, db.QueryRow(ctx, "SELECT count(*) FROM artifact_refs WHERE root=$1 AND hash=ANY($2)", "run:"+runID, hashes).Scan(&references))
	if references != len(hashes) {
		t.Fatal("manifest or part lost its run retention reference", references, len(hashes))
	}
	return m, all
}

func TestNativeArchiveCommittedReplyLoss(t *testing.T) {
	dir := os.Getenv("NATIVE_ARCHIVE_EVIDENCE")
	if dir == "" {
		t.Skip("explicit isolated native archive acceptance not configured")
	}
	need(t, os.Mkdir(dir, 0700))
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Second)
	defer cancel()
	u, e := url.Parse(os.Getenv("TEST_DATABASE_URL"))
	need(t, e)
	if (u.Scheme != "postgres" && u.Scheme != "postgresql") || u.Host != "127.0.0.1:55432" || u.Path != "/postgres" || u.RawQuery != "sslmode=disable" || u.Fragment != "" || u.User == nil || u.User.Username() != "agentos_mac_test" {
		t.Fatal("requires the independent Mac loopback fixture administrator")
	}
	paths := map[string]string{}
	hashes := map[string]string{}
	for _, k := range []string{"RUNTIME", "WORKER", "STORAGE", "RUNTIME_MIGRATOR", "STORAGE_MIGRATOR", "NODE", "RUNNER"} {
		p := os.Getenv("NATIVE_ARCHIVE_" + k)
		if !filepath.IsAbs(p) {
			t.Fatal("absolute binary/runner input required", k)
		}
		b, e := os.ReadFile(p)
		need(t, e)
		paths[k] = p
		hashes[k] = hash(b)
	}
	save(t, dir, "inputs.json", object{"os": runtime.GOOS, "arch": runtime.GOARCH, "go": runtime.Version(), "engine": engine, "paths": paths, "sha256": hashes, "real_provider_calls": 0})
	admin, e := pgxpool.New(ctx, u.String())
	need(t, e)
	t.Cleanup(admin.Close)
	suffix := nonce(t)[:12]
	prefix := "na_" + suffix
	db := database(t, ctx, admin, u, dir, suffix, "runtime", paths["RUNTIME_MIGRATOR"], prefix+"_runtime", prefix+"_worker")
	storeDB := database(t, ctx, admin, u, dir, suffix, "storage", paths["STORAGE_MIGRATOR"], prefix+"_storage")
	tokens, peers := map[string]string{}, map[string]string{}
	for _, r := range []string{"runtime", "worker", "storage", "control", "toolhub"} {
		tokens[r] = nonce(t) + nonce(t)
		peers[r] = hash([]byte(tokens[r]))
	}
	var models, toolRoutes atomic.Int64
	final := "Synthetic actual 17; plan 20 remains separate."
	model := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Max      int               `json:"max_tokens"`
			Messages []json.RawMessage `json:"messages"`
		}
		if e := json.NewDecoder(io.LimitReader(r.Body, 8<<20)).Decode(&in); e != nil || in.Max != 393216 || len(in.Messages) == 0 {
			t.Error("frozen native model request changed")
			http.Error(w, "bad fixture request", 400)
			return
		}
		n := models.Add(1)
		message := object{"role": "assistant", "content": final}
		finish := "stop"
		if n == 1 {
			message["content"] = "Persist the supplied synthetic fact."
			message["tool_calls"] = []any{object{"id": "synthetic-note-1", "type": "function", "function": object{"name": "note_save", "arguments": string(raw(object{"kind": "fact", "title": "archive-loss-fixture", "content": "actual17;plan20", "source": "fixture://native-archive"}))}}}
			finish = "tool_calls"
		} else if n != 2 {
			t.Error("provider request duplicated", n)
			http.Error(w, "unexpected fixture request", 500)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(raw(object{"choices": []any{object{"message": message, "finish_reason": finish}}, "usage": object{"prompt_tokens": 1800, "completion_tokens": 100, "prompt_cache_hit_tokens": 900, "total_tokens": 1900}}))
	}))
	t.Cleanup(model.Close)
	ca := filepath.Join(dir, "fixture-ca.pem")
	need(t, os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: model.Certificate().Raw}), 0600))
	agent := object{"name": "Synthetic native archive fixture", "prompt": "Use only supplied synthetic facts; persist one note then finish.", "tools": []string{"note_save"}, "model": object{"base_url": model.URL, "model": "native-fixture", "max_tokens": 393216, "limits": object{"model": "native-fixture", "base_url": model.URL, "protocol": "openai-chat-completions", "context_window": 1048576, "max_output_tokens": 393216, "source": model.URL + "/models", "observed_at": "2026-10-15T00:00:00Z", "metadata_sha256": strings.Repeat("a", 64)}}, "max_steps": 6, "max_model_attempts": 4, "context_tokens": 1048576, "context_bytes": 64000, "max_children": 0}
	registry := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/resources/agent/fixture/1" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(raw(object{"kind": "agent", "id": "fixture", "revision": 1, "spec": agent}))
	}))
	t.Cleanup(registry.Close)
	runtimeURL, storageURL := "http://"+address(t), "http://"+address(t)
	var invMu sync.Mutex
	var invocation []byte
	hub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+tokens["worker"] {
			http.Error(w, "unauthorized", 403)
			return
		}
		b, e := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		if e != nil {
			http.Error(w, "read", 400)
			return
		}
		out, status, e := request(r.Context(), "POST", runtimeURL+"/invoke", tokens["toolhub"], b)
		if e != nil {
			http.Error(w, "runtime transport", 502)
			return
		}
		toolRoutes.Add(1)
		invMu.Lock()
		invocation = append([]byte(nil), b...)
		invMu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write(out)
	}))
	t.Cleanup(hub.Close)
	type heldUpload struct {
		Hash     string
		Manifest manifest
		At       time.Time
	}
	held := make(chan heldUpload, 1)
	var selected atomic.Bool
	var release atomic.Bool
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "PUT" || r.Header.Get("Authorization") != "Bearer "+tokens["worker"] {
			http.Error(w, "unexpected archive caller", 403)
			return
		}
		b, e := io.ReadAll(io.LimitReader(r.Body, (4<<20)+1))
		if e != nil || len(b) > 4<<20 {
			http.Error(w, "bounded body", 413)
			return
		}
		up, e := http.NewRequestWithContext(r.Context(), r.Method, storageURL+r.URL.Path, bytes.NewReader(b))
		if e != nil {
			http.Error(w, "request", 500)
			return
		}
		up.Header = r.Header.Clone()
		client := http.Client{Timeout: 10 * time.Second}
		res, e := client.Do(up)
		if e != nil {
			http.Error(w, "storage transport", 503)
			return
		}
		out, e := io.ReadAll(io.LimitReader(res.Body, 1<<20))
		res.Body.Close()
		if e != nil {
			http.Error(w, "storage response", 503)
			return
		}
		if res.StatusCode == 200 && r.Header.Get("X-Artifact-Media-Type") == "application/vnd.agentos.event-manifest+json" && !release.Load() {
			var m manifest
			var completed int
			if json.Unmarshal(b, &m) == nil && db.pool.QueryRow(r.Context(), "SELECT count(*) FROM calls WHERE run_id=$1 AND kind='tool' AND request->>'name'='note_save' AND status='completed'", m.RunID).Scan(&completed) == nil && completed == 1 && selected.CompareAndSwap(false, true) {
				held <- heldUpload{hash(b), m, time.Now()}
				<-r.Context().Done()
				return
			}
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(res.StatusCode)
		_, _ = w.Write(out)
	}))
	t.Cleanup(proxy.Close)
	base := map[string]string{"SERVICE_PEERS": string(raw(peers)), "REGISTRY_URL": registry.URL, "TOOLHUB_URL": hub.URL, "RUNTIME_URL": runtimeURL, "STORAGE_URL": proxy.URL, "DB_MAX_CONNS": "3", "GOMEMLIMIT": "96MiB"}
	conf := func(role, name, listen, dsn string) map[string]string {
		c := map[string]string{}
		for k, v := range base {
			c[k] = v
		}
		c["SERVICE_TOKEN"] = tokens[role]
		c["INSTANCE_ID"] = name
		c["LISTEN"] = listen
		c["DATABASE_URL"] = dsn
		return c
	}
	rc := conf("runtime", "archive-runtime", strings.TrimPrefix(runtimeURL, "http://"), db.dsns[prefix+"_runtime"])
	rc["DEFAULT_RUN_ENGINE"] = engine
	start(t, ctx, dir, "runtime", paths["RUNTIME"], rc)
	sc := conf("storage", "archive-storage", strings.TrimPrefix(storageURL, "http://"), storeDB.dsns[prefix+"_storage"])
	storage := start(t, ctx, dir, "storage-first", paths["STORAGE"], sc)
	ready(t, ctx, runtimeURL, tokens["control"])
	ready(t, ctx, storageURL, tokens["control"])
	worker := func(name string) *child {
		c := conf("worker", name, address(t), db.dsns[prefix+"_worker"])
		c["AGENTOS_NODE"] = paths["NODE"]
		c["DSH_NATIVE_RUNNER"] = paths["RUNNER"]
		c["SSL_CERT_FILE"] = ca
		c["GODEBUG"] = "x509sslcertoverrideplatform=1"
		c["GOMEMLIMIT"] = "192MiB"
		p := start(t, ctx, dir, name, paths["WORKER"], c)
		ready(t, ctx, "http://"+c["LISTEN"], tokens["worker"])
		return p
	}
	first := worker("archive-first")
	var submitted struct{ ID string }
	need(t, json.Unmarshal(ok(t, ctx, "POST", runtimeURL+"/v1/runs", tokens["control"], object{"agent": object{"id": "fixture", "revision": 1}, "task": "Synthetic actual17 and plan20. Save exactly one note then finish."}), &submitted))
	if len(submitted.ID) != 32 {
		t.Fatal("invalid new run id")
	}
	var fault heldUpload
	select {
	case fault = <-held:
	case <-ctx.Done():
		t.Fatal("archive commit fault not reached")
	case <-first.done:
		t.Fatal("Worker exited before archive fault")
	}
	if fault.Manifest.RunID != submitted.ID || fault.Manifest.SourceFence != 1 || fault.Manifest.SourceOwner != "archive-first" {
		t.Fatal("fault has wrong ownership")
	}
	var batch []byte
	var acknowledged string
	need(t, db.pool.QueryRow(ctx, "SELECT batch,manifest_hash FROM harness_archives WHERE run_id=$1 AND seq=$2", submitted.ID, fault.Manifest.Exchange).Scan(&batch, &acknowledged))
	if len(batch) == 0 || acknowledged != "" || hash(batch) != fault.Manifest.SHA256 || models.Load() != 1 || toolRoutes.Load() != 1 {
		t.Fatal("archive acknowledgement barrier crossed before failure")
	}
	invMu.Lock()
	oldInvocation := append([]byte(nil), invocation...)
	invMu.Unlock()
	if len(oldInvocation) == 0 {
		t.Fatal("committed note invocation missing")
	}
	var preservedNote, preservedReceipt []byte
	need(t, db.pool.QueryRow(ctx, "SELECT response FROM calls WHERE run_id=$1 AND kind='tool' AND request->>'name'='note_save' AND status='completed'", submitted.ID).Scan(&preservedReceipt))
	var note struct{ ID string }
	need(t, json.Unmarshal(preservedReceipt, &note))
	need(t, db.pool.QueryRow(ctx, "SELECT row_to_json(d)::text FROM documents d WHERE id=$1", note.ID).Scan(&preservedNote))
	save(t, dir, "fault.json", object{"run_id": submitted.ID, "manifest": fault.Hash, "exchange": fault.Manifest.Exchange, "source_owner": fault.Manifest.SourceOwner, "source_fence": fault.Manifest.SourceFence, "batch_sha256": hash(batch), "note_sha256": hash(preservedNote), "receipt_sha256": hash(preservedReceipt), "models_before": models.Load(), "tools_before": toolRoutes.Load(), "at": fault.At, "storage_http_committed": true, "runtime_manifest_acknowledged": false})
	first.stop(t)
	release.Store(true)
	storage.stop(t)
	start(t, ctx, dir, "storage-restarted", paths["STORAGE"], sc)
	ready(t, ctx, storageURL, tokens["control"])
	m, recovered := readArchive(t, ctx, storeDB.pool, storageURL, tokens["control"], fault.Hash, submitted.ID)
	if !bytes.Equal(recovered, batch) || m.SourceFence != 1 {
		t.Fatal("committed original archive did not survive Storage restart")
	}
	var noteNow, receiptNow []byte
	need(t, db.pool.QueryRow(ctx, "SELECT row_to_json(d)::text FROM documents d WHERE id=$1", note.ID).Scan(&noteNow))
	need(t, db.pool.QueryRow(ctx, "SELECT response FROM calls WHERE run_id=$1 AND kind='tool' AND request->>'name'='note_save' AND status='completed'", submitted.ID).Scan(&receiptNow))
	if !bytes.Equal(preservedNote, noteNow) || !bytes.Equal(preservedReceipt, receiptNow) || models.Load() != 1 || toolRoutes.Load() != 1 {
		t.Fatal("pre-retry evidence changed")
	}
	save(t, dir, "before-retry.json", object{"manifest": fault.Hash, "parts": len(m.Parts), "bytes": len(recovered), "original_bytes_equal": true, "note_and_receipt_equal": true, "storage_restarted": true, "manifest_and_part_retention_root_verified": "run:" + submitted.ID})
	worker("archive-replacement")
	var result struct {
		Status, Owner, Engine string
		Fence                 int64
		State                 struct{ Result, Error string }
	}
	for {
		need(t, json.Unmarshal(ok(t, ctx, "GET", runtimeURL+"/v1/runs/"+submitted.ID, tokens["control"], nil), &result))
		if result.Status == "completed" {
			break
		}
		if result.Status == "failed" || result.Status == "waiting_unknown" || result.Status == "cancelled" {
			t.Fatal("recovery terminal failure", result.Status, result.State.Error)
		}
		select {
		case <-ctx.Done():
			t.Fatal("natural lease recovery timeout")
		case <-time.After(50 * time.Millisecond):
		}
	}
	if result.Engine != engine || result.Fence != 2 || result.Owner != "archive-replacement" || result.State.Result != final || models.Load() != 2 || toolRoutes.Load() != 1 {
		t.Fatal("recovery replay duplicated effects or changed result", result.Status, result.Fence, models.Load(), toolRoutes.Load())
	}
	_, oldStatus, e := request(ctx, "POST", runtimeURL+"/invoke", tokens["toolhub"], oldInvocation)
	need(t, e)
	if oldStatus != http.StatusPreconditionFailed {
		t.Fatal("stale fence was not rejected", oldStatus)
	}
	var pending, notes, attempts int
	need(t, db.pool.QueryRow(ctx, "SELECT count(*) FROM harness_archives WHERE run_id=$1 AND (batch IS NOT NULL OR manifest_hash='')", submitted.ID).Scan(&pending))
	need(t, db.pool.QueryRow(ctx, "SELECT count(*) FROM documents WHERE title='archive-loss-fixture'").Scan(&notes))
	need(t, db.pool.QueryRow(ctx, "SELECT count(*) FROM model_attempts a JOIN calls c ON c.id=a.call_id WHERE c.run_id=$1", submitted.ID).Scan(&attempts))
	if pending != 0 || notes != 1 || attempts != 2 {
		t.Fatal("durable receipt count mismatch", pending, notes, attempts)
	}
	var faultHash string
	need(t, db.pool.QueryRow(ctx, "SELECT manifest_hash FROM harness_archives WHERE run_id=$1 AND seq=$2", submitted.ID, m.Exchange).Scan(&faultHash))
	if faultHash != fault.Hash {
		t.Fatal("replacement regenerated first archive instead of retaining it")
	}
	rows, e := db.pool.Query(ctx, "SELECT manifest_hash FROM harness_archives WHERE run_id=$1 ORDER BY seq", submitted.ID)
	need(t, e)
	var allHashes []string
	for rows.Next() {
		var h string
		need(t, rows.Scan(&h))
		allHashes = append(allHashes, h)
	}
	need(t, rows.Err())
	rows.Close()
	previous := ""
	end := 0
	total := 0
	for _, h := range allHashes {
		a, b := readArchive(t, ctx, storeDB.pool, storageURL, tokens["control"], h, submitted.ID)
		if a.Previous != previous || a.EventStart != end {
			t.Fatal("archive chain changed after takeover")
		}
		previous = h
		end = a.EventEnd
		total += len(b)
	}
	need(t, db.pool.QueryRow(ctx, "SELECT row_to_json(d)::text FROM documents d WHERE id=$1", note.ID).Scan(&noteNow))
	need(t, db.pool.QueryRow(ctx, "SELECT response FROM calls WHERE run_id=$1 AND kind='tool' AND request->>'name'='note_save' AND status='completed'", submitted.ID).Scan(&receiptNow))
	if !bytes.Equal(preservedNote, noteNow) || !bytes.Equal(preservedReceipt, receiptNow) {
		t.Fatal("replay changed original note or receipt")
	}
	usage := ok(t, ctx, "GET", runtimeURL+"/v1/runs/"+submitted.ID+"/usage", tokens["control"], nil)
	save(t, dir, "usage.json", json.RawMessage(usage))
	save(t, dir, "result.json", object{"passed": true, "run_id": submitted.ID, "engine": engine, "fence": result.Fence, "owner": result.Owner, "model_requests": models.Load(), "real_provider_calls": 0, "tool_routes": toolRoutes.Load(), "notes": notes, "model_attempts": attempts, "old_fence_http_status": oldStatus, "manifest_count": len(allHashes), "archive_bytes": total, "pending_batches": pending, "natural_lease_takeover": true, "sql_mutated_run_or_receipt": false, "storage_restart_before_retries": true, "all_manifest_and_part_retention_roots_verified": true, "elapsed_after_fault_ms": time.Since(fault.At).Milliseconds(), "scope": "Mac independent binary and database fixture; no ENOSPC, PostgreSQL restart, Windows release or real model claim"})
	t.Logf("native-v4 real Storage reply-loss recovery: fence=%d models=%d tools=%d manifests=%d bytes=%d; natural lease, no real model", result.Fence, models.Load(), toolRoutes.Load(), len(allHashes), total)
}
