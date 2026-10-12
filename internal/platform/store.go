package platform

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/euler-gaozl/agent-os/internal/serviceclient"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Store struct {
	DB         *pgxpool.Pool
	CatalogURL string
	StorageURL string
	Remote     *serviceclient.Client
}

func Open(ctx context.Context, url string) (*Store, error) {
	config, err := pgxpool.ParseConfig(url)
	if err != nil {
		return nil, err
	}
	config.MaxConns = 8
	p, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		return nil, err
	}
	if err = p.Ping(ctx); err != nil {
		p.Close()
		return nil, err
	}
	return &Store{DB: p}, nil
}
func (s *Store) Migrate(ctx context.Context) error {
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(8843921)"); err != nil {
		return err
	}
	for _, domain := range []string{"legacy_versions", "registry", "runtime", "storage", "sandbox", "telemetry", "legacy_knowledge"} {
		body, err := migrationSQL.ReadFile("migrations/" + domain + ".sql")
		if err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, string(body)); err != nil {
			return err
		}
	}
	if err = migratePublications(ctx, tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
func event(ctx context.Context, tx pgx.Tx, id, kind string, v any) error {
	_, e := tx.Exec(ctx, "INSERT INTO events(run_id,kind,payload) VALUES($1,$2,$3)", id, kind, JSON(v))
	return e
}
func (s *Store) PutResource(ctx context.Context, kind, id string, spec json.RawMessage) (Resource, error) {
	if s.CatalogURL != "" && (kind == "skill" || kind == "connector") {
		var result Resource
		e := s.Remote.Request(ctx, "POST", s.CatalogURL+"/v1/assets", map[string]any{"kind": kind, "id": id, "spec": spec}, &result)
		return result, e
	}
	tx, e := s.DB.Begin(ctx)
	if e != nil {
		return Resource{}, e
	}
	defer tx.Rollback(ctx)
	if _, e = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", kind+":"+id); e != nil {
		return Resource{}, e
	}
	var rev int
	e = tx.QueryRow(ctx, "SELECT COALESCE(MAX(revision),0)+1 FROM resources WHERE kind=$1 AND id=$2", kind, id).Scan(&rev)
	if e != nil {
		return Resource{}, e
	}
	_, e = tx.Exec(ctx, "INSERT INTO resources(kind,id,revision,spec) VALUES($1,$2,$3,$4)", kind, id, rev, spec)
	if e != nil {
		return Resource{}, e
	}
	return Resource{Kind: kind, ID: id, Revision: rev, Spec: spec}, tx.Commit(ctx)
}
func (s *Store) Resource(ctx context.Context, kind string, r Ref, dst any) error {
	if s.Remote != nil {
		if s.CatalogURL != "" && (kind == "skill" || kind == "connector") {
			return s.Remote.Resource(ctx, kind, r, dst)
		}
		if s.Remote.RegistryURL != "" {
			return s.Remote.Resource(ctx, kind, r, dst)
		}
	}
	var b []byte
	e := s.DB.QueryRow(ctx, "SELECT spec FROM resources WHERE kind=$1 AND id=$2 AND revision=$3", kind, r.ID, r.Revision).Scan(&b)
	if e != nil {
		return e
	}
	return json.Unmarshal(b, dst)
}
func (s *Store) Resources(ctx context.Context, after ...string) ([]Resource, error) {
	cursor := ""
	if len(after) > 0 {
		cursor = after[0]
	}
	rows, e := s.DB.Query(ctx, `SELECT kind,id,revision,spec FROM resources a WHERE kind!='action'
 AND ($2 OR kind NOT IN ('skill','connector')) AND (kind||':'||id) COLLATE "C">$1
 AND revision=(SELECT max(b.revision) FROM resources b WHERE b.kind=a.kind AND b.id=a.id)
 ORDER BY (kind||':'||id) COLLATE "C" LIMIT 100`, cursor, s.CatalogURL == "")
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []Resource{}
	size := 0
	for rows.Next() {
		var r Resource
		if e = rows.Scan(&r.Kind, &r.ID, &r.Revision, &r.Spec); e != nil {
			return nil, e
		}
		if s.CatalogURL == "" || (r.Kind != "skill" && r.Kind != "connector") {
			n := len(JSON(r))
			if len(out) > 0 && size+n > 2<<20 {
				break
			}
			size += n
			out = append(out, r)
		}
	}
	if e = rows.Err(); e != nil {
		return nil, e
	}
	return out, nil
}
func (s *Store) Snapshot(ctx context.Context, ref Ref, depth int) (Snapshot, error) {
	out := Snapshot{AgentRef: ref, Children: map[string]Snapshot{}, Knowledge: map[string]KnowledgeBase{}}
	if depth > 2 {
		return out, errors.New("child agent binding depth exceeds 2")
	}
	if e := s.Resource(ctx, "agent", ref, &out.Agent); e != nil {
		return out, e
	}
	if e := out.Agent.Validate(); e != nil {
		return out, e
	}
	for _, r := range out.Agent.Prompts {
		var p Skill
		if e := s.Resource(ctx, "prompt", r, &p); e != nil {
			return out, e
		}
		out.Agent.Prompt += "\n\n" + p.Content
	}
	for _, r := range out.Agent.Skills {
		var v Skill
		if e := s.Resource(ctx, "skill", r, &v); e != nil {
			return out, e
		}
		out.Skills = append(out.Skills, v)
	}
	for _, r := range out.Agent.Connectors {
		var v Connector
		if e := s.Resource(ctx, "connector", r, &v); e != nil {
			return out, e
		}
		v.Name = r.ID
		out.Connectors = append(out.Connectors, v)
	}
	for _, r := range out.Agent.ChildAgents {
		v, e := s.Snapshot(ctx, r, depth+1)
		if e != nil {
			return out, e
		}
		out.Children[r.ID] = v
	}
	for _, r := range out.Agent.Knowledge {
		var kb KnowledgeBase
		if e := s.Resource(ctx, "knowledge", r, &kb); e != nil {
			return out, e
		}
		if e := kb.Validate(); e != nil {
			return out, e
		}
		out.Knowledge[r.ID] = kb
	}
	return out, nil
}
func insertRun(ctx context.Context, tx pgx.Tx, key, task string, snap Snapshot, parent *string, pinned []string) (string, error) {
	constraints := append(append([]string{}, snap.Agent.Constraints...), pinned...)
	id := ID()
	inputHash := Hash(JSON([]any{task, snap, parent, pinned}))
	state := RunState{Pinned: pinned, Messages: []Message{{Role: "user", Content: task}}}
	var actual, oldHash string
	e := tx.QueryRow(ctx, `INSERT INTO runs(id,submission_key,input_hash,parent_id,snapshot,task,state,constraints) VALUES($1,$2,$3,$4,$5,$6,$7,$8)
 ON CONFLICT(submission_key) DO UPDATE SET submission_key=EXCLUDED.submission_key RETURNING id,input_hash`, id, key, inputHash, parent, JSON(snap), task, JSON(state), JSON(constraints)).Scan(&actual, &oldHash)
	if e != nil {
		return "", e
	}
	if oldHash != inputHash {
		return "", errors.New("idempotency key reused with different input")
	}
	if actual == id {
		if e = event(ctx, tx, id, "accepted", map[string]any{"agent": snap.AgentRef}); e != nil {
			return "", e
		}
	}
	return actual, nil
}
func (s *Store) Submit(ctx context.Context, key, task string, snap Snapshot, pinned []string) (string, error) {
	tx, e := s.DB.Begin(ctx)
	if e != nil {
		return "", e
	}
	defer tx.Rollback(ctx)
	id, e := insertRun(ctx, tx, key, task, snap, nil, pinned)
	if e != nil {
		return "", e
	}
	return id, tx.Commit(ctx)
}

const runColumns = "id,parent_id,task,snapshot,status,step,state,owner,fence,constraints,rule_revision,cancel_requested,created_at,updated_at,engine"

func scanRun(row pgx.Row) (Run, error) {
	var r Run
	var snap, state, constraints []byte
	e := row.Scan(&r.ID, &r.ParentID, &r.Task, &snap, &r.Status, &r.Step, &state, &r.Owner, &r.Fence, &constraints, &r.RuleRevision, &r.CancelRequested, &r.CreatedAt, &r.UpdatedAt, &r.Engine)
	if e != nil {
		return r, e
	}
	if e = json.Unmarshal(snap, &r.Snapshot); e != nil {
		return r, e
	}
	if e = json.Unmarshal(constraints, &r.Constraints); e != nil {
		return r, e
	}
	e = json.Unmarshal(state, &r.State)
	return r, e
}
func (s *Store) Run(ctx context.Context, id string) (Run, error) {
	return scanRun(s.DB.QueryRow(ctx, "SELECT "+runColumns+" FROM runs WHERE id=$1", id))
}
func (s *Store) Runs(ctx context.Context) ([]Run, error) {
	rows, e := s.DB.Query(ctx, `SELECT id,parent_id,left(task,500),jsonb_build_object('agent',jsonb_build_object('name',snapshot#>>'{agent,name}'),'agent_ref',snapshot->'agent_ref'),status,step,'{}'::jsonb,owner,fence,'[]'::jsonb,rule_revision,cancel_requested,created_at,updated_at,engine FROM runs ORDER BY created_at DESC LIMIT 100`)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []Run{}
	for rows.Next() {
		r, e := scanRun(rows)
		if e != nil {
			return nil, e
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
func (s *Store) Claim(ctx context.Context, owner string, lease time.Duration) (Run, error) {
	tx, e := s.DB.Begin(ctx)
	if e != nil {
		return Run{}, e
	}
	defer tx.Rollback(ctx)
	r, e := scanRun(tx.QueryRow(ctx, `UPDATE runs SET status='running',owner=$1,fence=fence+1,lease_until=clock_timestamp()+$2::interval,updated_at=now()
 WHERE id=(SELECT id FROM runs r WHERE status='queued' OR (status='running' AND lease_until<clock_timestamp()) OR (status='waiting_children' AND NOT EXISTS(SELECT 1 FROM runs c WHERE c.parent_id=r.id AND c.status NOT IN('completed','failed','cancelled'))) ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING `+runColumns, owner, fmt.Sprintf("%f seconds", lease.Seconds())))
	if e != nil {
		return r, e
	}
	if e = event(ctx, tx, r.ID, "claimed", map[string]any{"owner": owner, "fence": r.Fence}); e != nil {
		return r, e
	}
	return r, tx.Commit(ctx)
}
func lockRun(ctx context.Context, tx pgx.Tx, id, owner string, fence int64, allowCancel bool) error {
	var valid bool
	e := tx.QueryRow(ctx, "SELECT owner=$2 AND fence=$3 AND status='running' AND lease_until>clock_timestamp() AND ($4 OR NOT cancel_requested) FROM runs WHERE id=$1 FOR UPDATE", id, owner, fence, allowCancel).Scan(&valid)
	if e != nil {
		return e
	}
	if !valid {
		return ErrFence
	}
	return nil
}
func (s *Store) Heartbeat(ctx context.Context, r Run, lease time.Duration) error {
	tag, e := s.DB.Exec(ctx, "UPDATE runs SET lease_until=clock_timestamp()+$4::interval WHERE id=$1 AND owner=$2 AND fence=$3 AND status='running' AND NOT cancel_requested AND lease_until>clock_timestamp()", r.ID, r.Owner, r.Fence, fmt.Sprintf("%f seconds", lease.Seconds()))
	if e != nil {
		return e
	}
	if tag.RowsAffected() != 1 {
		return ErrFence
	}
	return nil
}
func (s *Store) Save(ctx context.Context, r Run, status string) error {
	tx, e := s.DB.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	if e = lockRun(ctx, tx, r.ID, r.Owner, r.Fence, status == "cancelled" || status == "waiting_unknown" || status == "waiting_children"); e != nil {
		return e
	}
	if status == "completed" {
		var revision int64
		if e = tx.QueryRow(ctx, "SELECT rule_revision FROM runs WHERE id=$1", r.ID).Scan(&revision); e != nil {
			return e
		}
		if revision != r.RuleRevision {
			return errors.New("constraints changed before completion; resume with current constraints")
		}
	}
	_, e = tx.Exec(ctx, "UPDATE runs SET state=$2,step=$3,status=$4,updated_at=now() WHERE id=$1", r.ID, JSON(r.State), r.Step, status)
	if e != nil {
		return e
	}
	if e = event(ctx, tx, r.ID, "checkpoint", map[string]any{"step": r.Step, "status": status, "result": r.State.Result, "error": r.State.Error}); e != nil {
		return e
	}
	return tx.Commit(ctx)
}
func (s *Store) Cancel(ctx context.Context, id string) error {
	tx, e := s.DB.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	ids, e := lockFamily(ctx, tx, id)
	if e != nil {
		return e
	}
	_, e = tx.Exec(ctx, `UPDATE runs r SET cancel_requested=true,status=CASE WHEN status IN('queued','waiting_children','failed') THEN CASE WHEN EXISTS(SELECT 1 FROM runs c WHERE c.parent_id=r.id AND c.status NOT IN('completed','failed','cancelled')) THEN 'waiting_children' ELSE 'cancelled' END ELSE status END,updated_at=now() WHERE id=ANY($1) AND status NOT IN('completed','cancelled')`, ids)
	if e != nil {
		return e
	}
	if e = event(ctx, tx, id, "cancel_requested", map[string]any{}); e != nil {
		return e
	}
	return tx.Commit(ctx)
}

// Lock parents before discovering children. A concurrent spawn must commit before
// we enumerate its children, or observe the new cancellation/constraint revision.
func lockFamily(ctx context.Context, tx pgx.Tx, id string) ([]string, error) {
	var root string
	if e := tx.QueryRow(ctx, "SELECT id FROM runs WHERE id=$1 FOR UPDATE", id).Scan(&root); e != nil {
		return nil, e
	}
	ids, frontier := []string{root}, []string{root}
	for len(frontier) > 0 {
		rows, e := tx.Query(ctx, "SELECT id FROM runs WHERE parent_id=ANY($1) ORDER BY id FOR UPDATE", frontier)
		if e != nil {
			return nil, e
		}
		next := []string{}
		for rows.Next() {
			var child string
			if e = rows.Scan(&child); e != nil {
				rows.Close()
				return nil, e
			}
			next = append(next, child)
		}
		e = rows.Err()
		rows.Close()
		if e != nil {
			return nil, e
		}
		ids = append(ids, next...)
		frontier = next
	}
	return ids, nil
}
func (s *Store) Events(ctx context.Context, id string, after int64) ([]Event, error) {
	rows, e := s.DB.Query(ctx, "SELECT seq,kind,payload,created_at FROM events WHERE run_id=$1 AND seq>$2 ORDER BY seq LIMIT 500", id, after)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []Event{}
	for rows.Next() {
		var v Event
		if e = rows.Scan(&v.Seq, &v.Kind, &v.Payload, &v.CreatedAt); e != nil {
			return nil, e
		}
		out = append(out, v)
	}
	return out, rows.Err()
}
