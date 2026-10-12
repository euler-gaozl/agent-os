package platform

import (
	"context"
	"embed"
	"errors"

	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed migrations/*.sql
var migrationSQL embed.FS

// MigrateService changes only one owner's objects. Worker consumes Runtime's
// schema, including Agent-scoped notes committed with tool receipts. Storage
// owns immutable artifact bytes and references, without execution tables.
func MigrateService(ctx context.Context, db *pgxpool.Pool, service string) error {
	if service == "worker" {
		service = "runtime"
	}
	switch service {
	case "registry", "runtime", "storage", "sandbox", "telemetry":
	default:
		return errors.New("unknown platform migration owner")
	}
	body, e := migrationSQL.ReadFile("migrations/" + service + ".sql")
	if e != nil {
		return e
	}
	tx, e := db.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	// Also serialize with the historical bootstrap/import job.
	if _, e = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(8843921)"); e != nil {
		return e
	}
	if _, e = tx.Exec(ctx, string(body)); e != nil {
		return e
	}
	return tx.Commit(ctx)
}
