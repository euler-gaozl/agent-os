package platform

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/euler-gaozl/agent-os/internal/recordstore"
	"github.com/euler-gaozl/agent-os/internal/serviceclient"
	"github.com/euler-gaozl/agent-os/internal/servicehttp"
	storageapi "github.com/euler-gaozl/agent-os/services/storage"
)

// Real ENOSPC on a bounded tmpfs inside a disposable PostgreSQL container.
// No host directory is mounted or filled; no real model or user DB is used.
func TestPostgresDiskFullPreservesReceiptsAndRecovers(t *testing.T) {
	if os.Getenv("TEST_POSTGRES_DISK_FULL") != "1" {
		t.Skip("isolated Linux Docker fixture required")
	}
	if os.Getenv("GITHUB_ACTIONS") != "true" {
		t.Fatal("disk-full acceptance runs only on disposable GitHub CI")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	name := "agentos-diskfull-" + ID()
	command := func(args ...string) (string, error) {
		c, stop := context.WithTimeout(ctx, 30*time.Second)
		defer stop()
		b, e := exec.CommandContext(c, "docker", args...).CombinedOutput()
		return string(b), e
	}
	// Keep the container alive when PostgreSQL exits: restarting the container
	// would discard its tmpfs and falsely replace retained data with an empty DB.
	_, e := command("run", "-d", "--name", name, "--label", "agentos.test=disk-full", "--memory", "512m", "--cpus", "1", "--tmpfs", "/var/lib/postgresql:rw,size=192m,mode=1777", "-p", "127.0.0.1::5432", "-e", "POSTGRES_PASSWORD=disposable-diskfull-fixture", "-e", "POSTGRES_DB=agentos", "-e", "PGDATA=/var/lib/postgresql/fixture-data", "--entrypoint", "sh", "postgres:18", "-c", "docker-entrypoint.sh postgres -c shared_buffers=16MB -c max_connections=16 -c max_wal_size=64MB & child=$!; wait \"$child\"; exec sleep infinity")
	if e != nil {
		t.Fatal("start bounded PostgreSQL fixture", e)
	}
	defer func() {
		cleanup, done := context.WithTimeout(context.Background(), 30*time.Second)
		defer done()
		if t.Failed() {
			if logs, e := exec.CommandContext(cleanup, "docker", "logs", "--tail", "80", name).CombinedOutput(); e == nil {
				t.Log(string(logs))
			}
		}
		if _, e := exec.CommandContext(cleanup, "docker", "rm", "-f", name).CombinedOutput(); e != nil {
			t.Error("dispose bounded fixture", e)
		}
	}()
	port, e := command("port", name, "5432/tcp")
	if e != nil {
		t.Fatal(e)
	}
	port = strings.TrimSpace(port)
	if !strings.HasPrefix(port, "127.0.0.1:") {
		t.Fatal("fixture must be loopback-only")
	}
	dsn := "postgres://postgres:disposable-diskfull-fixture@" + port + "/agentos?sslmode=disable"
	var runtime *Store
	for end := time.Now().Add(45 * time.Second); time.Now().Before(end); {
		probe, stop := context.WithTimeout(ctx, 2*time.Second)
		runtime, e = Open(probe, dsn)
		stop()
		if e == nil {
			break
		}
		time.Sleep(250 * time.Millisecond)
	}
	if e != nil {
		t.Fatal("PostgreSQL did not start")
	}
	defer runtime.DB.Close()
	if e = MigrateService(ctx, runtime.DB, "runtime"); e != nil {
		t.Fatal(e)
	}
	if _, e = runtime.DB.Exec(ctx, "CREATE DATABASE artifact_store"); e != nil {
		t.Fatal(e)
	}
	retained, e := Open(ctx, strings.Replace(dsn, "/agentos?", "/artifact_store?", 1))
	if e != nil {
		t.Fatal(e)
	}
	defer retained.DB.Close()
	if e = MigrateService(ctx, retained.DB, "storage"); e != nil {
		t.Fatal(e)
	}
	store := &recordstore.Store{DB: retained.DB}
	server := httptest.NewServer((&storageapi.Server{Store: store, HTTP: servicehttp.Config{Role: "storage", Peers: map[string]string{"runtime": servicehttp.TokenHash(testToken)}}}).Handler())
	defer server.Close()
	runtime.Remote = &serviceclient.Client{Token: testToken}
	runtime.StorageURL = server.URL
	id := submit(t, runtime, basicSnapshot("https://fixture.invalid"))
	run := claim(t, runtime, "before-full")
	if _, e = runtime.DB.Exec(ctx, "UPDATE runs SET lease_until=now()+interval '3 minutes' WHERE id=$1", id); e != nil {
		t.Fatal(e)
	}
	initial := invocation(run)
	before, e := runtime.LocalTool(ctx, initial)
	if e != nil {
		t.Fatal(e)
	}
	baseline := []byte("committed artifact before disk exhaustion")
	oldHash, e := runtime.PutArtifact(ctx, baseline, "text/plain", "run:"+id)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = runtime.DB.Exec(ctx, "CHECKPOINT"); e != nil {
		t.Fatal(e)
	}
	fill, e := command("exec", "--user", "postgres", name, "dd", "if=/dev/zero", "of=/var/lib/postgresql/diskfull-fixture", "bs=4096")
	if e == nil || !strings.Contains(fill, "No space left on device") {
		t.Fatal("ENOSPC not reached on bounded volume", e, fill)
	}
	df, e := command("exec", name, "df", "-Pk", "/var/lib/postgresql")
	if e != nil {
		t.Fatal(e)
	}
	lines := strings.Split(strings.TrimSpace(df), "\n")
	fields := strings.Fields(lines[len(lines)-1])
	if len(fields) < 4 {
		t.Fatal("invalid bounded volume measurement")
	}
	free, e := strconv.Atoi(fields[3])
	if e != nil || free != 0 {
		t.Fatal("volume not full", free, e)
	}
	t.Log("Verified ENOSPC and zero available KiB on the 192 MiB fixture volume")
	random := make([]byte, 12<<10)
	if _, e = rand.Read(random); e != nil {
		t.Fatal(e)
	}
	inv := invocation(run)
	inv.OperationID += "/disk-full"
	inv.Arguments = JSON(map[string]any{"kind": "memory", "title": "disk-full attempt", "content": base64.StdEncoding.EncodeToString(random), "source": "fixture://disk-full"})
	attempt, stop := context.WithTimeout(ctx, 5*time.Second)
	_, noteErr := runtime.LocalTool(attempt, inv)
	stop()
	if noteErr == nil {
		t.Fatal("new toasted note unexpectedly fit on the exhausted volume")
	}
	t.Logf("Runtime note rejected while full: %v", noteErr)
	payload := make([]byte, 1<<20)
	if _, e = rand.Read(payload); e != nil {
		t.Fatal(e)
	}
	attempt, stop = context.WithTimeout(ctx, 5*time.Second)
	_, artifactErr := runtime.PutArtifact(attempt, payload, "application/octet-stream", "run:"+id)
	stop()
	if artifactErr == nil {
		t.Fatal("artifact upload falsely succeeded with no space")
	}
	t.Logf("Storage artifact rejected while full: %v", artifactErr)
	// Release only the explicitly created fixture file. Restart the DB process
	// against the same volume to exercise recovery, not an empty replacement.
	if _, e = command("exec", name, "rm", "--", "/var/lib/postgresql/diskfull-fixture"); e != nil {
		t.Fatal(e)
	}
	// pg_ctl addresses only this fixture's PGDATA. A server already terminated
	// by ENOSPC needs no second stop; still require it to be down before start.
	_, _ = command("exec", "--user", "postgres", name, "pg_ctl", "-D", "/var/lib/postgresql/fixture-data", "stop", "-m", "immediate", "-w", "-t", "10")
	probe, done := context.WithTimeout(ctx, 2*time.Second)
	if e = runtime.DB.Ping(probe); e == nil {
		done()
		t.Fatal("database never stopped before recovery")
	}
	done()
	if _, e = command("exec", "--user", "postgres", name, "pg_ctl", "-D", "/var/lib/postgresql/fixture-data", "-l", "/tmp/recovery.log", "start", "-w", "-t", "25"); e != nil {
		t.Fatal("restart PostgreSQL on retained volume", e)
	}
	for end := time.Now().Add(45 * time.Second); time.Now().Before(end); {
		probe, done := context.WithTimeout(ctx, 2*time.Second)
		e = runtime.DB.Ping(probe)
		done()
		if e == nil {
			break
		}
		time.Sleep(250 * time.Millisecond)
	}
	if e != nil {
		t.Fatal("database did not recover after space was freed")
	}
	// Read the original committed effects BEFORE any replay or upload can repair
	// missing data. A surviving call receipt alone does not prove note retention.
	checkNote := func(op string, receipt []byte) {
		t.Helper()
		var expected, actual Document
		if e := json.Unmarshal(receipt, &expected); e != nil || expected.ID == "" {
			t.Fatal("invalid note receipt", e)
		}
		var metadata, saved []byte
		e := runtime.DB.QueryRow(ctx, "SELECT id,kind,title,content,source,metadata,supersedes,scope,valid_until FROM documents WHERE id=$1", expected.ID).Scan(&actual.ID, &actual.Kind, &actual.Title, &actual.Content, &actual.Source, &metadata, &actual.Supersedes, &actual.Scope, &actual.ValidUntil)
		if e != nil || json.Unmarshal(metadata, &actual.Metadata) != nil || canonicalHash(JSON(expected)) != canonicalHash(JSON(actual)) {
			t.Fatal("committed note content or metadata lost", e)
		}
		var count int
		e = runtime.DB.QueryRow(ctx, "SELECT response FROM calls WHERE id=$1 AND run_id=$2 AND status='completed'", op, id).Scan(&saved)
		if e != nil || canonicalHash(receipt) != canonicalHash(saved) {
			t.Fatal("committed note receipt lost", e)
		}
		e = runtime.DB.QueryRow(ctx, "SELECT count(*) FROM events WHERE run_id=$1 AND kind='tool_completed' AND payload->>'operation_id'=$2", id, op).Scan(&count)
		if e != nil || count != 1 {
			t.Fatal("committed note event lost or duplicated", count, e)
		}
	}
	checkNote(initial.OperationID, before)
	old, media, e := store.Artifact(ctx, oldHash)
	if e != nil || string(old) != string(baseline) || media != "text/plain" {
		t.Fatal("old artifact lost before retries", e)
	}
	var artifacts, refs int
	if e = retained.DB.QueryRow(ctx, "SELECT count(*) FROM artifact_refs WHERE hash=$1 AND root=$2", oldHash, "run:"+id).Scan(&refs); e != nil || refs != 1 {
		t.Fatal("old artifact reference lost before retries", refs, e)
	}
	if e = retained.DB.QueryRow(ctx, "SELECT (SELECT count(*) FROM artifacts WHERE hash=$1),(SELECT count(*) FROM artifact_refs WHERE hash=$1 AND root=$2)", Hash(payload), "run:"+id).Scan(&artifacts, &refs); e != nil || artifacts != refs || artifacts > 1 {
		t.Fatal("partial failed artifact survived before retries", artifacts, refs, e)
	}
	if artifacts == 1 {
		body, _, err := store.Artifact(ctx, Hash(payload))
		if err != nil || Hash(body) != Hash(payload) {
			t.Fatal("ambiguous committed artifact corrupted", err)
		}
	}
	var docs, calls, events int
	if e = runtime.DB.QueryRow(ctx, `SELECT (SELECT count(*) FROM documents WHERE title='disk-full attempt'),(SELECT count(*) FROM calls WHERE id=$1 AND status='completed'),(SELECT count(*) FROM events WHERE kind='tool_completed' AND payload->>'operation_id'=$1)`, inv.OperationID).Scan(&docs, &calls, &events); e != nil || docs != calls || calls != events || docs > 1 {
		t.Fatal("partial note/receipt/event survived", docs, calls, events, e)
	}
	if docs == 1 {
		var receipt []byte
		if e = runtime.DB.QueryRow(ctx, "SELECT response FROM calls WHERE id=$1", inv.OperationID).Scan(&receipt); e != nil {
			t.Fatal(e)
		}
		checkNote(inv.OperationID, receipt)
	}
	if _, e = runtime.DB.Exec(ctx, "UPDATE runs SET lease_until=now()-interval '1 second' WHERE id=$1", id); e != nil {
		t.Fatal(e)
	}
	newOwner := claim(t, runtime, "after-full")
	if newOwner.ID != id || newOwner.Fence <= run.Fence {
		t.Fatal("run not taken over with a new fence")
	}
	if _, e = runtime.LocalTool(ctx, inv); e == nil {
		t.Fatal("old instance wrote after recovery")
	}
	initial.Owner, initial.Fence = newOwner.Owner, newOwner.Fence
	replayed, e := runtime.LocalTool(ctx, initial)
	if e != nil || canonicalHash(before) != canonicalHash(replayed) {
		t.Fatal("known committed note changed", e)
	}
	inv.Owner, inv.Fence = newOwner.Owner, newOwner.Fence
	first, e := runtime.LocalTool(ctx, inv)
	if e != nil {
		t.Fatal("note retry failed", e)
	}
	second, e := runtime.LocalTool(ctx, inv)
	if e != nil || canonicalHash(first) != canonicalHash(second) {
		t.Fatal("recovery duplicated logical note", e)
	}
	if e = runtime.DB.QueryRow(ctx, "SELECT count(*) FROM documents WHERE title='disk-full attempt'").Scan(&docs); e != nil || docs != 1 {
		t.Fatal("note count after recovery", docs, e)
	}
	for _, body := range [][]byte{baseline, payload} {
		hash, e := runtime.PutArtifact(ctx, body, "application/octet-stream", "run:"+id)
		if e != nil {
			t.Fatal("artifact retry failed", e)
		}
		bytes, _, e := store.Artifact(ctx, hash)
		if e != nil || Hash(bytes) != Hash(body) {
			t.Fatal("artifact data corrupted", e)
		}
	}
	if e = retained.DB.QueryRow(ctx, "SELECT (SELECT count(*) FROM artifacts),(SELECT count(*) FROM artifact_refs)").Scan(&artifacts, &refs); e != nil || artifacts != 2 || refs != 2 {
		t.Fatal("partial artifact reference or duplicate", artifacts, refs, e)
	}
	var state []struct {
		State        struct{ OOMKilled bool }
		RestartCount int
	}
	raw, e := command("inspect", name)
	if e != nil || json.Unmarshal([]byte(raw), &state) != nil || len(state) != 1 || state[0].State.OOMKilled {
		t.Fatal("disk test replaced by memory exhaustion", e)
	}
	t.Log(fmt.Sprintf("Recovery verified: one logical note, matching receipt/event, %d intact artifacts and references, old fence rejected; not a physical power-loss or HA test", artifacts))
}
