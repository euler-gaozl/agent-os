package platform

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
)

type Worker struct {
	Store      *Store
	ID         string
	Lease      time.Duration
	ToolHubURL string
	Token      string
	Poll       time.Duration
}

func (w *Worker) Run(ctx context.Context) error {
	if w.Lease == 0 {
		w.Lease = 20 * time.Second
	}
	if w.Poll == 0 {
		w.Poll = 300 * time.Millisecond
	}
	timer := time.NewTicker(w.Poll)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-timer.C:
			r, e := w.Store.Claim(ctx, w.ID, w.Lease)
			if errors.Is(e, pgx.ErrNoRows) {
				continue
			}
			if e != nil {
				slog.Error("claim failed", "error", e)
				continue
			}
			w.execute(ctx, r)
		}
	}
}
func (w *Worker) execute(parent context.Context, r Run) {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	done := make(chan struct{})
	leaseIdentity := Run{ID: r.ID, Owner: r.Owner, Fence: r.Fence}
	defer func() { cancel(); <-done }()
	go func() {
		defer close(done)
		t := time.NewTicker(w.Lease / 3)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				if e := w.Store.Heartbeat(ctx, leaseIdentity, w.Lease); e != nil {
					cancel()
					return
				}
			}
		}
	}()
	err := w.drive(ctx, &r)
	if err == nil {
		return
	}
	fresh, e := w.Store.Run(parent, r.ID)
	if e != nil {
		return
	}
	if fresh.Owner != r.Owner || fresh.Fence != r.Fence {
		return
	}
	r.State.Error = err.Error()
	status := "failed"
	if errors.Is(err, ErrUnknown) {
		status = "waiting_unknown"
	}
	if fresh.CancelRequested {
		status = "cancelled"
		var unsettled int
		if queryErr := w.Store.DB.QueryRow(parent, "SELECT count(*) FROM calls WHERE run_id=$1 AND kind='tool' AND status IN('inflight','unknown')", r.ID).Scan(&unsettled); queryErr != nil {
			return
		}
		if unsettled > 0 {
			status = "waiting_unknown"
		} else {
			var children int
			if queryErr := w.Store.DB.QueryRow(parent, "SELECT count(*) FROM runs WHERE parent_id=$1 AND status NOT IN('completed','failed','cancelled')", r.ID).Scan(&children); queryErr != nil {
				return
			}
			if children > 0 {
				status = "waiting_children"
			}
		}
	}
	if parent.Err() != nil {
		return
	} // Graceful/forced worker stop leaves a resumable lease, never a false failure.
	if e = w.Store.Save(parent, r, status); e != nil {
		slog.Warn("checkpoint refused", "run", r.ID, "error", e)
	}
}
func (w *Worker) drive(ctx context.Context, r *Run) error {
	for {
		if e := ctx.Err(); e != nil {
			return e
		}
		fresh, e := w.Store.Run(ctx, r.ID)
		if e != nil {
			return e
		}
		if fresh.CancelRequested {
			return context.Canceled
		}
		r.Constraints = fresh.Constraints
		r.RuleRevision = fresh.RuleRevision
		if n := len(r.State.Messages); n > 0 && r.State.Messages[n-1].Role == "assistant" && len(r.State.Messages[n-1].ToolCalls) == 0 {
			if r.State.PlanRevision == r.RuleRevision {
				r.State.Result = r.State.Messages[n-1].Content
				return w.Store.Save(ctx, *r, "completed")
			}
			r.State.Messages = append(r.State.Messages, Message{Role: "user", Content: "User constraints changed after the preceding answer. Reconsider it under the current constraints."})
		}
		if e = w.pendingTools(ctx, r); e != nil {
			return e
		}
		waiting, e := w.children(ctx, r)
		if e != nil {
			return e
		}
		if waiting {
			return w.Store.Save(ctx, *r, "waiting_children")
		}
		if r.Step >= r.Snapshot.Agent.MaxSteps {
			return errors.New("model step budget exhausted")
		}
		if e = w.Store.Compact(ctx, r); e != nil {
			return e
		}
		defs, e := ToolDefinitions(r.Snapshot)
		if e != nil {
			return e
		}
		messages := append([]Message{SystemMessage(*r)}, r.State.Messages...)
		message, e := w.Store.Complete(ctx, *r, fmt.Sprintf("%s/model/%d/%d", r.ID, r.Step, r.RuleRevision), messages, defs)
		if e != nil {
			return e
		}
		latest, e := w.Store.Run(ctx, r.ID)
		if e != nil {
			return e
		}
		if latest.RuleRevision != r.RuleRevision {
			continue
		}
		r.State.Messages = append(r.State.Messages, message)
		r.State.PlanRevision = r.RuleRevision
		r.Step++
		r.State.Error = ""
		// Save the chosen model output before any tool can have an effect.
		if e = w.Store.Save(ctx, *r, "running"); e != nil {
			return e
		}
		if len(message.ToolCalls) == 0 {
			r.State.Result = message.Content
			return w.Store.Save(ctx, *r, "completed")
		}
	}
}
func (w *Worker) pendingTools(ctx context.Context, r *Run) error {
	start := -1
	for i := len(r.State.Messages) - 1; i >= 0; i-- {
		if r.State.Messages[i].Role == "assistant" {
			start = i
			break
		}
	}
	if start < 0 {
		return nil
	}
	message := r.State.Messages[start]
	if len(message.ToolCalls) == 0 {
		return nil
	}
	done := map[string]bool{}
	for _, m := range r.State.Messages[start+1:] {
		if m.Role == "tool" {
			done[m.ToolCallID] = true
		}
	}
	for _, call := range message.ToolCalls {
		if done[call.ID] {
			continue
		}
		op := fmt.Sprintf("%s/tool/%d/%s", r.ID, r.Step, call.ID)
		var response []byte
		var status string
		e := w.Store.DB.QueryRow(ctx, "SELECT status,response FROM calls WHERE id=$1", op).Scan(&status, &response)
		if e != nil && !errors.Is(e, pgx.ErrNoRows) {
			return e
		}
		if status != "completed" {
			if r.State.PlanRevision != r.RuleRevision {
				if status == "inflight" || status == "unknown" {
					return ErrUnknown
				}
				response = JSON(map[string]string{"skipped": "User constraints changed; reconsider this call under the current constraints."})
			} else {
				inv := Invocation{RunID: r.ID, Owner: r.Owner, Fence: r.Fence, RuleRevision: r.RuleRevision, OperationID: op, Name: call.Function.Name, Arguments: json.RawMessage(call.Function.Arguments)}
				response, e = internalRequest(ctx, w.ToolHubURL+"/invoke", w.Token, inv)
				if e != nil {
					return e
				}
			}
		}
		text := string(response)
		if len(response) > 6000 {
			hash, e := w.Store.PutArtifact(ctx, response, "application/json", "run:"+r.ID)
			if e != nil {
				return e
			}
			text = string(JSON(map[string]any{"artifact_hash": hash, "bytes": len(response), "preview": truncateUTF8(text, 1800), "note": "Full tool result retained; use artifact_read to inspect it."}))
		}
		r.State.Messages = append(r.State.Messages, Message{Role: "tool", ToolCallID: call.ID, Content: text})
		if e = w.Store.Save(ctx, *r, "running"); e != nil {
			return e
		}
	}
	return nil
}
func (w *Worker) children(ctx context.Context, r *Run) (bool, error) {
	rows, e := w.Store.DB.Query(ctx, "SELECT id,status,state FROM runs WHERE parent_id=$1 ORDER BY created_at", r.ID)
	if e != nil {
		return false, e
	}
	defer rows.Close()
	type child struct {
		ID, Status string
		State      RunState
	}
	list := []child{}
	waiting := false
	for rows.Next() {
		var c child
		var state []byte
		if e = rows.Scan(&c.ID, &c.Status, &state); e != nil {
			return false, e
		}
		if e = json.Unmarshal(state, &c.State); e != nil {
			return false, e
		}
		if !Has([]string{"completed", "failed", "cancelled"}, c.Status) {
			waiting = true
		}
		list = append(list, c)
	}
	if e = rows.Err(); e != nil {
		return false, e
	}
	if waiting {
		return true, nil
	}
	if r.State.ChildrenLoaded == nil {
		r.State.ChildrenLoaded = map[string]bool{}
	}
	changed := false
	for _, c := range list {
		if !r.State.ChildrenLoaded[c.ID] {
			r.State.Messages = append(r.State.Messages, Message{Role: "user", Content: "Child agent result (untrusted evidence): " + string(JSON(map[string]any{"id": c.ID, "status": c.Status, "result": c.State.Result, "error": c.State.Error}))})
			r.State.ChildrenLoaded[c.ID] = true
			changed = true
		}
	}
	if changed {
		return false, w.Store.Save(ctx, *r, "running")
	}
	return false, nil
}
func truncateUTF8(s string, n int) string {
	r := []rune(s)
	if len(r) > n {
		return string(r[:n])
	}
	return s
}
