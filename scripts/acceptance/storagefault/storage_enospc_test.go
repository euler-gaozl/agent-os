//go:build darwin

// Package storagefault tests the independent Storage executable. The outer
// controller owns the disposable disk image and cleanup even if go test times out.
package storagefault

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const capBytes = 512 << 20

type fixture struct {
	Root, Mount, Image, Marker, Nonce, PGData, PGBin, PGLog, Evidence string
	AdminURL, DatabaseURL, StorageURL, WriterToken, ReaderToken       string
	VolumeDev                                                         uint64
	Port                                                              int
}

func need(t *testing.T, e error) {
	t.Helper()
	if e != nil {
		t.Fatal(e)
	}
}
func digest(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func save(t *testing.T, f fixture, name string, v any) {
	t.Helper()
	b, e := json.MarshalIndent(v, "", "  ")
	need(t, e)
	need(t, os.WriteFile(filepath.Join(f.Evidence, name), append(b, '\n'), 0600))
}

func volume(t *testing.T, f fixture) syscall.Statfs_t {
	t.Helper()
	platform := os.Getenv("STORAGE_ENOSPC_WORKSPACE")
	if !filepath.IsAbs(platform) || platform == string(filepath.Separator) || filepath.Clean(platform) != platform {
		t.Fatal("explicit absolute workspace required")
	}
	physical, err := filepath.EvalSymlinks(platform)
	need(t, err)
	if physical != platform {
		t.Fatal("workspace must be physical")
	}
	nonce, e := hex.DecodeString(f.Nonce)
	if e != nil || len(nonce) != 16 || hex.EncodeToString(nonce) != f.Nonce || f.Root != platform+"/local/data/storage-enospc-"+f.Nonce || f.Mount != filepath.Join(f.Root, "volume") || f.Image != filepath.Join(f.Root, "volume.dmg") || f.Marker != filepath.Join(f.Mount, ".agentos-enospc") || f.PGData != filepath.Join(f.Mount, "pgdata") || f.Evidence != platform+"/local/evidence/storage-enospc-"+f.Nonce || f.PGBin != platform+"/local/toolchains/postgresql-18.6/bin" || f.PGLog != filepath.Join(f.Root, "postgres.log") {
		t.Fatal("unexpected fixture path identity")
	}
	for _, p := range []string{f.Root, f.Mount, f.PGData, f.Evidence} {
		r, e := filepath.EvalSymlinks(p)
		need(t, e)
		if r != p {
			t.Fatal("fixture path must be physical")
		}
	}
	owner, e := os.ReadFile(filepath.Join(f.Root, ".fixture-owner"))
	need(t, e)
	if string(owner) != f.Nonce {
		t.Fatal("fixture owner marker mismatch")
	}
	image, e := os.Lstat(f.Image)
	need(t, e)
	if !image.Mode().IsRegular() || image.Size() > capBytes {
		t.Fatal("fixture image is not a bounded regular file")
	}
	marker, e := os.ReadFile(f.Marker)
	need(t, e)
	if string(marker) != f.Nonce {
		t.Fatal("mounted volume marker mismatch")
	}
	mi, e := os.Stat(f.Mount)
	need(t, e)
	ri, e := os.Stat(f.Root)
	need(t, e)
	if uint64(mi.Sys().(*syscall.Stat_t).Dev) != f.VolumeDev || mi.Sys().(*syscall.Stat_t).Dev == ri.Sys().(*syscall.Stat_t).Dev {
		t.Fatal("fixture mount device mismatch")
	}
	var st syscall.Statfs_t
	need(t, syscall.Statfs(f.Mount, &st))
	if st.Blocks*uint64(st.Bsize) > capBytes {
		t.Fatal("volume exceeds fixed 512 MiB bound")
	}
	return st
}

func postmaster(t *testing.T, f fixture, allowStopped bool) int {
	t.Helper()
	volume(t, f)
	b, e := os.ReadFile(filepath.Join(f.PGData, "postmaster.pid"))
	if errors.Is(e, os.ErrNotExist) && allowStopped {
		return 0
	}
	need(t, e)
	lines := strings.Split(string(b), "\n")
	if len(lines) < 2 || lines[1] != f.PGData {
		t.Fatal("postmaster data directory identity mismatch")
	}
	pid, e := strconv.Atoi(lines[0])
	need(t, e)
	if pid <= 1 {
		t.Fatal("invalid fixture postmaster pid")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	out, e := exec.CommandContext(ctx, "/bin/ps", "-p", strconv.Itoa(pid), "-o", "command=").Output()
	if e != nil && allowStopped && errors.Is(syscall.Kill(pid, 0), syscall.ESRCH) {
		return 0
	}
	need(t, e)
	fields := strings.Fields(strings.TrimSpace(string(out)))
	if len(fields) < 3 || fields[0] != filepath.Join(f.PGBin, "postgres") {
		t.Fatal("postmaster executable identity mismatch")
	}
	found := false
	for i := 1; i+1 < len(fields); i++ {
		if fields[i] == "-D" && fields[i+1] == f.PGData {
			found = true
		}
	}
	if !found {
		t.Fatal("postmaster command does not belong to fixture")
	}
	return pid
}

func httpCall(ctx context.Context, f fixture, method, path, token, root string, body []byte) ([]byte, int, error) {
	r, e := http.NewRequestWithContext(ctx, method, f.StorageURL+path, bytes.NewReader(body))
	if e != nil {
		return nil, 0, e
	}
	r.Header.Set("Authorization", "Bearer "+token)
	if method == http.MethodPut {
		r.Header.Set("X-Artifact-Root", root)
		r.Header.Set("X-Artifact-Media-Type", "application/octet-stream")
	}
	c := http.Client{Timeout: 7 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("redirect refused") }}
	res, e := c.Do(r)
	if e != nil {
		return nil, 0, e
	}
	defer res.Body.Close()
	b, e := io.ReadAll(io.LimitReader(res.Body, 4<<20))
	return b, res.StatusCode, e
}

func verifyArtifact(t *testing.T, ctx context.Context, f fixture, db *pgxpool.Pool, body []byte, root string) {
	t.Helper()
	h := digest(body)
	out, status, e := httpCall(ctx, f, "GET", "/artifacts/"+h, f.ReaderToken, "", nil)
	need(t, e)
	if status != 200 || !bytes.Equal(out, body) {
		t.Fatal("retained artifact differs", status)
	}
	var artifacts, refs int
	need(t, db.QueryRow(ctx, "SELECT (SELECT count(*) FROM artifacts WHERE hash=$1),(SELECT count(*) FROM artifact_refs WHERE root=$2 AND hash=$1)", h, root).Scan(&artifacts, &refs))
	if artifacts != 1 || refs != 1 {
		t.Fatal("artifact/retention root lost", artifacts, refs)
	}
}

// Require a new PostgreSQL disk-space error from this fault window. HTTP 503
// alone can also mean an unrelated connection or readiness failure.
func diskErrorLines(t *testing.T, f fixture, before os.FileInfo) []string {
	t.Helper()
	current, e := os.Lstat(f.PGLog)
	need(t, e)
	if !current.Mode().IsRegular() || !os.SameFile(before, current) || current.Size() < before.Size() || current.Size()-before.Size() > 4<<20 {
		t.Fatal("fixture PostgreSQL log identity or bounded tail changed")
	}
	log, e := os.Open(f.PGLog)
	need(t, e)
	defer log.Close()
	_, e = log.Seek(before.Size(), io.SeekStart)
	need(t, e)
	b, e := io.ReadAll(io.LimitReader(log, 4<<20))
	need(t, e)
	var matches []string
	for _, line := range strings.Split(string(b), "\n") {
		if strings.Contains(line, "No space left on device") && (strings.Contains(line, "ERROR:") || strings.Contains(line, "FATAL:") || strings.Contains(line, "PANIC:")) {
			matches = append(matches, line)
		}
	}
	return matches
}

func TestStorageDiskFullRetainsArtifacts(t *testing.T) {
	config := os.Getenv("STORAGE_ENOSPC_FIXTURE")
	if config == "" {
		t.Skip("explicit disposable Mac volume controller required")
	}
	fi, e := os.Lstat(config)
	need(t, e)
	if !fi.Mode().IsRegular() || fi.Mode().Perm()&0077 != 0 {
		t.Fatal("private regular fixture config required")
	}
	raw, e := os.ReadFile(config)
	need(t, e)
	var f fixture
	need(t, json.Unmarshal(raw, &f))
	volume(t, f)
	if config != filepath.Join(f.Root, "fixture.json") || f.Port < 1024 || f.Port > 65535 {
		t.Fatal("unexpected fixture config or port")
	}
	initialPID := postmaster(t, f, false)
	for _, dsn := range []struct{ value, database string }{{f.AdminURL, "/postgres"}, {f.DatabaseURL, "/enospc_storage"}} {
		u, e := url.Parse(dsn.value)
		if e != nil || u.Scheme != "postgres" || u.Host != fmt.Sprintf("127.0.0.1:%d", f.Port) || u.RawQuery != "sslmode=disable" || u.Fragment != "" || u.Path != dsn.database || u.RawPath != "" || u.Opaque != "" || u.User == nil || u.User.Username() != "enospc_admin" {
			t.Fatal("unexpected isolated database endpoint")
		}
	}
	endpoint, e := url.Parse(f.StorageURL)
	if e != nil || endpoint.Scheme != "http" || endpoint.Hostname() != "127.0.0.1" || endpoint.User != nil || endpoint.RawQuery != "" || endpoint.Fragment != "" || endpoint.Path != "" || endpoint.Opaque != "" {
		t.Fatal("unexpected Storage fixture endpoint")
	}
	storagePort, e := strconv.Atoi(endpoint.Port())
	need(t, e)
	if storagePort < 1024 || storagePort > 65535 || storagePort == f.Port || endpoint.Host != fmt.Sprintf("127.0.0.1:%d", storagePort) {
		t.Fatal("unexpected Storage fixture port")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Second)
	defer cancel()
	admin, e := pgxpool.New(ctx, f.AdminURL)
	need(t, e)
	defer admin.Close()
	db, e := pgxpool.New(ctx, f.DatabaseURL)
	need(t, e)
	defer db.Close()
	var data, systemID string
	var port int
	need(t, admin.QueryRow(ctx, "SELECT current_setting('data_directory'),inet_server_port(),system_identifier::text FROM pg_control_system()").Scan(&data, &port, &systemID))
	if data != f.PGData || port != f.Port {
		t.Fatal("connected cluster is not the disposable fixture")
	}
	root := "run:" + f.Nonce
	baseline := []byte("Committed synthetic artifact; retain its exact bytes and run reference after real ENOSPC.")
	_, status, e := httpCall(ctx, f, "PUT", "/v1/artifacts/"+digest(baseline), f.WriterToken, root, baseline)
	need(t, e)
	if status != 200 {
		t.Fatal("baseline artifact write failed", status)
	}
	verifyArtifact(t, ctx, f, db, baseline, root)
	_, e = admin.Exec(ctx, "CHECKPOINT")
	need(t, e)
	initialVolume := volume(t, f)
	postmaster(t, f, false)
	logBeforeFault, e := os.Lstat(f.PGLog)
	need(t, e)
	if !logBeforeFault.Mode().IsRegular() {
		t.Fatal("fixture PostgreSQL log must be a regular file")
	}
	fillPath := filepath.Join(f.Mount, "fill-"+f.Nonce)
	fd, e := syscall.Open(fillPath, syscall.O_WRONLY|syscall.O_CREAT|syscall.O_EXCL|syscall.O_NOFOLLOW, 0600)
	need(t, e)
	file := os.NewFile(uintptr(fd), fillPath)
	defer file.Close()
	opened, e := file.Stat()
	need(t, e)
	if uint64(opened.Sys().(*syscall.Stat_t).Dev) != f.VolumeDev {
		t.Fatal("fill file is not on the bounded volume")
	}
	written := int64(0)
	if initialVolume.Bsize < 1 || initialVolume.Bsize > 1<<20 {
		t.Fatal("unexpected fixture filesystem block size")
	}
	var fillStages []map[string]any
	// HFS+ may reject a large extension while retaining smaller allocatable
	// extents or filesystem reserve blocks. Exercise block and byte writes too;
	// record the remaining statfs blocks rather than pretending they are zero.
	for _, size := range []int{1 << 20, int(initialVolume.Bsize), 1} {
		chunk := make([]byte, size)
		start := written
		var fullErr error
		for written+int64(size) <= capBytes {
			if ctx.Err() != nil {
				t.Fatal("bounded fill timed out")
			}
			n, err := file.Write(chunk)
			written += int64(n)
			if err != nil {
				fullErr = err
				break
			}
			if n != len(chunk) {
				t.Fatal("short fill without an error")
			}
		}
		if !errors.Is(fullErr, syscall.ENOSPC) {
			t.Fatal("actual ENOSPC not reached at fill granularity within fixed bound", size)
		}
		st := volume(t, f)
		fillStages = append(fillStages, map[string]any{"write_size": size, "bytes_written": written - start, "write_enospc": true, "available_blocks": st.Bavail, "available_bytes": st.Bavail * uint64(st.Bsize)})
	}
	if e = file.Sync(); e != nil && !errors.Is(e, syscall.ENOSPC) {
		need(t, e)
	}
	if e = file.Close(); e != nil && !errors.Is(e, syscall.ENOSPC) {
		need(t, e)
	}
	full := volume(t, f)
	payload := make([]byte, 1<<20)
	_, e = rand.Read(payload)
	need(t, e)
	_, status, e = httpCall(ctx, f, "PUT", "/v1/artifacts/"+digest(payload), f.WriterToken, root, payload)
	var pgErrors []string
	for until := time.Now().Add(2 * time.Second); time.Now().Before(until); {
		pgErrors = diskErrorLines(t, f, logBeforeFault)
		if len(pgErrors) > 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	save(t, f, "fault.json", map[string]any{"enospc": true, "fill_stages": fillStages, "volume_capacity_bytes": full.Blocks * uint64(full.Bsize), "available_blocks": full.Bavail, "available_bytes": full.Bavail * uint64(full.Bsize), "filler_bytes": written, "failed_put_http_status": status, "postgres_disk_errors": pgErrors, "baseline_sha256": digest(baseline), "payload_sha256": digest(payload), "root": root, "initial_postmaster_pid": initialPID})
	need(t, e)
	if status != http.StatusServiceUnavailable {
		t.Fatal("Storage did not report unavailable during real ENOSPC", status)
	}
	if len(pgErrors) == 0 {
		t.Fatal("PostgreSQL did not record a disk-space error during this fault window")
	}
	// Free only the unique file whose inode and device were created above. The
	// outer controller owns emergency cleanup if this test exits before here.
	volume(t, f)
	current, e := os.Lstat(fillPath)
	need(t, e)
	if !os.SameFile(opened, current) {
		t.Fatal("fill file identity changed")
	}
	need(t, os.Remove(fillPath))
	postmaster(t, f, true)
	stopCtx, stopCancel := context.WithTimeout(ctx, 15*time.Second)
	stop := exec.CommandContext(stopCtx, filepath.Join(f.PGBin, "pg_ctl"), "-D", f.PGData, "stop", "-m", "immediate", "-w", "-t", "10")
	stop.Env = []string{"LC_ALL=C", "LANG=C"}
	_ = stop.Run()
	stopCancel()
	if postmaster(t, f, true) != 0 {
		t.Fatal("fixture PostgreSQL did not stop before recovery")
	}
	admin.Reset()
	db.Reset()
	probe, done := context.WithTimeout(ctx, time.Second)
	err := admin.Ping(probe)
	done()
	if err == nil {
		t.Fatal("old database endpoint still accepts queries")
	}
	volume(t, f)
	startCtx, startCancel := context.WithTimeout(ctx, 20*time.Second)
	start := exec.CommandContext(startCtx, filepath.Join(f.PGBin, "pg_ctl"), "-D", f.PGData, "-l", f.PGLog, "start", "-w", "-t", "15")
	start.Env = []string{"LC_ALL=C", "LANG=C"}
	e = start.Run()
	startCancel()
	need(t, e)
	recoveredPID := postmaster(t, f, false)
	admin.Reset()
	db.Reset()
	ready := false
	for until := time.Now().Add(7 * time.Second); time.Now().Before(until); {
		_, s, err := httpCall(ctx, f, "GET", "/readyz", f.ReaderToken, "", nil)
		if err == nil && s == 200 {
			ready = true
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !ready {
		t.Fatal("Storage did not reconnect after fixture PostgreSQL recovery")
	}
	var recoveredID string
	need(t, admin.QueryRow(ctx, "SELECT system_identifier::text FROM pg_control_system()").Scan(&recoveredID))
	if recoveredID != systemID {
		t.Fatal("recovery replaced the cluster instead of retaining it")
	}
	// Read existing bytes and both sides of the atomic write before retrying;
	// otherwise a retry could hide missing data by recreating it.
	verifyArtifact(t, ctx, f, db, baseline, root)
	var artifacts, refs int
	need(t, db.QueryRow(ctx, "SELECT (SELECT count(*) FROM artifacts WHERE hash=$1),(SELECT count(*) FROM artifact_refs WHERE root=$2 AND hash=$1)", digest(payload), root).Scan(&artifacts, &refs))
	if artifacts != refs || artifacts > 1 {
		t.Fatal("partial artifact/reference survived failure", artifacts, refs)
	}
	if artifacts == 1 {
		verifyArtifact(t, ctx, f, db, payload, root)
	}
	save(t, f, "before-retry.json", map[string]any{"baseline_bytes_and_root_retained": true, "failed_write_artifacts": artifacts, "failed_write_refs": refs, "same_cluster_system_identifier": true, "recovered_postmaster_pid": recoveredPID})
	for i := 0; i < 2; i++ {
		_, status, e = httpCall(ctx, f, "PUT", "/v1/artifacts/"+digest(payload), f.WriterToken, root, payload)
		need(t, e)
		if status != 200 {
			t.Fatal("retry after recovery failed", status)
		}
	}
	verifyArtifact(t, ctx, f, db, baseline, root)
	verifyArtifact(t, ctx, f, db, payload, root)
	need(t, db.QueryRow(ctx, "SELECT (SELECT count(*) FROM artifacts),(SELECT count(*) FROM artifact_refs)").Scan(&artifacts, &refs))
	if artifacts != 2 || refs != 2 {
		t.Fatal("repeated upload duplicated retained effects", artifacts, refs)
	}
	save(t, f, "result.json", map[string]any{"passed": true, "real_enospc": true, "same_pgdata_recovery": true, "artifacts": artifacts, "references": refs, "real_provider_calls": 0, "scope": "Mac bounded-volume PostgreSQL and independent Storage artifact/reference atomicity; excludes Runtime note/call receipts, Windows and host-disk exhaustion"})
}
