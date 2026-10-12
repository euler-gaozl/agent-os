package servicehost

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Zero-row probes validate this version's schema and SELECT permissions without
// reading user data. A TCP connection alone does not make an unmigrated service
// ready for traffic. Downstream outages remain separate from local readiness.
func SchemaReadiness(role string, db *pgxpool.Pool) func(context.Context) error {
	if role == "control" || role == "futures" {
		return nil
	}
	if role == "worker" {
		role = "runtime"
	}
	if role == "indexer" {
		role = "knowledge"
	}
	queries := map[string]string{
		"registry":  "SELECT r.kind,r.revision,r.spec,s.sealed FROM resources r,secrets s WHERE false",
		"toolhub":   "SELECT a.definition_hash,s.check_fence,s.check_until,f.body,u.seq FROM assets a,asset_state s,asset_files f,asset_audit u WHERE false",
		"knowledge": "SELECT f.name_vector,f.config,c.search_vector,d.content,a.body,r.root FROM knowledge_files f,knowledge_chunks c,documents d,artifacts a,artifact_refs r WHERE false",
		"runtime":   "SELECT r.engine,r.rule_revision,c.request_hash,m.status,h.input_hash,d.scope,b.agent_revision,p.app,i.heartbeat_at,e.seq,e.telemetry_fence FROM runs r,calls c,model_attempts m,harness_exchanges h,documents d,business_runs b,app_runs p,instances i,events e WHERE false",
		"storage":   "SELECT d.scope,d.valid_until,a.body,r.root FROM documents d,artifacts a,artifact_refs r WHERE false",
		"sandbox":   "SELECT input_hash,container_name,status,result,cleaned_at FROM sandbox_jobs WHERE false",
		"telemetry": "SELECT e.seq,e.run_id,e.kind,e.created_at,e.exported_at,x.seq FROM telemetry_inbox e,telemetry_exports x WHERE false",
		"sources":   "SELECT c.hash,c.links,b.body FROM source_captures c,source_blobs b WHERE false",
	}
	query, known := queries[role]
	return func(ctx context.Context) error {
		if !known || db == nil {
			return errors.New("service schema probe is not configured")
		}
		_, e := db.Exec(ctx, query)
		return e
	}
}
