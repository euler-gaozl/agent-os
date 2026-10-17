package platform

import (
	"context"
	"errors"
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
	var err error
	if r.Engine == "legacy-go" {
		err = w.drive(ctx, &r)
	} else if r.Engine == "dsh-0.2.0-rc.2" || r.Engine == EngineDSHEvidence {
		err = w.driveDSH(ctx, &r)
	} else {
		err = errors.New("unsupported execution engine version")
	}
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
func truncateUTF8(s string, n int) string {
	r := []rune(s)
	if len(r) > n {
		return string(r[:n])
	}
	return s
}
