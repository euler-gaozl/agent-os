package platform

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

type boundedBuffer struct {
	bytes.Buffer
	Limit int
}

func (b *boundedBuffer) Write(p []byte) (int, error) {
	n := len(p)
	left := b.Limit - b.Len()
	if left > 0 {
		if len(p) > left {
			p = p[:left]
		}
		_, _ = b.Buffer.Write(p)
	}
	return n, nil
}
func docker(ctx context.Context, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "docker", args...)
	buf := &boundedBuffer{Limit: 65536}
	cmd.Stdout = buf
	cmd.Stderr = buf
	e := cmd.Run()
	return buf.String(), e
}
func (s *Server) sandboxRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /execute", wrap(func(w http.ResponseWriter, r *http.Request) error {
		var inv Invocation
		if e := decode(w, r, &inv); e != nil {
			return e
		}
		result, e := s.sandbox(r.Context(), inv)
		if e != nil {
			return e
		}
		w.Header().Set("Content-Type", "application/json")
		_, e = w.Write(result)
		return e
	}))
}
func (s *Server) sandbox(ctx context.Context, inv Invocation) ([]byte, error) {
	image := os.Getenv("SANDBOX_IMAGE")
	if !strings.Contains(image, "@sha256:") {
		return nil, errors.New("sandbox unavailable: configure a pinned SANDBOX_IMAGE and Docker; host execution is disabled")
	}
	tx, e := s.Store.DB.Begin(ctx)
	if e != nil {
		return nil, e
	}
	defer tx.Rollback(ctx)
	if _, e = checkInvocation(ctx, tx, inv); e != nil {
		return nil, e
	}
	if e = tx.Commit(ctx); e != nil {
		return nil, e
	}
	if inv.Name != "sandbox_exec" {
		return nil, errors.New("sandbox only accepts sandbox_exec")
	}
	if e = validateArgs(Builtins[4], inv.Arguments); e != nil {
		return nil, e
	}
	// Session advisory lock serializes service replicas for this deterministic job/container.
	conn, e := s.Store.DB.Acquire(ctx)
	if e != nil {
		return nil, e
	}
	defer conn.Release()
	lockKey := inv.OperationID
	if _, e = conn.Exec(ctx, "SELECT pg_advisory_lock(hashtextextended($1,21))", lockKey); e != nil {
		return nil, e
	}
	defer conn.Exec(context.Background(), "SELECT pg_advisory_unlock(hashtextextended($1,21))", lockKey)
	var oldHash, status string
	var result []byte
	name := "agentos-" + Hash([]byte(inv.OperationID))[:32]
	hash := invocationHash(inv)
	e = conn.QueryRow(ctx, "SELECT input_hash,status,result FROM sandbox_jobs WHERE id=$1", inv.OperationID).Scan(&oldHash, &status, &result)
	if e != nil && !errors.Is(e, pgx.ErrNoRows) {
		return nil, e
	}
	if e == nil {
		if oldHash != hash {
			return nil, errors.New("sandbox operation arguments changed")
		}
		if status == "completed" {
			return result, nil
		}
	} else {
		if _, e = conn.Exec(ctx, "INSERT INTO sandbox_jobs(id,input_hash,container_name,status) VALUES($1,$2,$3,'pending')", inv.OperationID, hash, name); e != nil {
			return nil, e
		}
	}
	var args struct {
		Code string `json:"code"`
	}
	if e = json.Unmarshal(inv.Arguments, &args); e != nil {
		return nil, e
	}
	jobCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	state, inspectErr := docker(jobCtx, "inspect", "--format", "{{.State.Status}}", name)
	if inspectErr != nil {
		// A daemon/network error is not proof that the container is absent.
		if !strings.Contains(strings.ToLower(state), "no such") {
			return nil, fmt.Errorf("sandbox inspect failed: %s", truncateUTF8(state, 300))
		}
		out, e := docker(jobCtx, "create", "--name", name, "--network", "none", "--read-only", "--memory", "128m", "--cpus", "0.5", "--pids-limit", "64", "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--user", "65534:65534", "--tmpfs", "/tmp:rw,noexec,nosuid,size=16m", "--label", "agentos.job="+inv.OperationID, image, "node", "--eval", args.Code)
		if e != nil {
			return nil, fmt.Errorf("sandbox create failed: %s", truncateUTF8(out, 300))
		}
		state = "created"
	}
	state = strings.TrimSpace(state)
	if state == "created" {
		if out, e := docker(jobCtx, "start", name); e != nil {
			return nil, fmt.Errorf("sandbox start failed: %s", truncateUTF8(out, 300))
		}
	}
	_, waitErr := docker(jobCtx, "wait", name)
	if waitErr != nil {
		cleanupCtx, c := context.WithTimeout(context.Background(), 5*time.Second)
		_, _ = docker(cleanupCtx, "kill", name)
		c()
		return nil, errors.New("sandbox interrupted; container stopped, reconcile on retry")
	}
	output, e := docker(jobCtx, "logs", name)
	if e != nil {
		return nil, e
	}
	exitCode, e := docker(jobCtx, "inspect", "--format", "{{.State.ExitCode}}", name)
	if e != nil {
		return nil, e
	}
	result = JSON(map[string]any{"stdout_and_stderr": output, "exit_code": strings.TrimSpace(exitCode), "output_capped_at_bytes": 65536, "container": name})
	if _, e = conn.Exec(ctx, "UPDATE sandbox_jobs SET status='completed',result=$2 WHERE id=$1", inv.OperationID, result); e != nil {
		return nil, e
	}
	// Keep container until its result is durable. Cleanup can safely repeat.
	cleanupCtx, c := context.WithTimeout(context.Background(), 5*time.Second)
	_, _ = docker(cleanupCtx, "rm", name)
	c()
	return result, nil
}
