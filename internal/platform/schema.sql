CREATE TABLE IF NOT EXISTS schema_versions(version integer PRIMARY KEY, installed_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS resources(
 kind text NOT NULL, id text NOT NULL, revision integer NOT NULL, spec jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(kind,id,revision));
CREATE TABLE IF NOT EXISTS runs(
 id text PRIMARY KEY, submission_key text UNIQUE NOT NULL, input_hash text NOT NULL,
 parent_id text REFERENCES runs(id), snapshot jsonb NOT NULL, task text NOT NULL,
 status text NOT NULL DEFAULT 'queued', step integer NOT NULL DEFAULT 0,
 state jsonb NOT NULL DEFAULT '{}', constraints jsonb NOT NULL DEFAULT '[]', rule_revision bigint NOT NULL DEFAULT 1,
 owner text NOT NULL DEFAULT '', fence bigint NOT NULL DEFAULT 0,
 lease_until timestamptz, cancel_requested boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS runs_claim ON runs(status,lease_until,created_at);
CREATE INDEX IF NOT EXISTS runs_parent ON runs(parent_id);
CREATE TABLE IF NOT EXISTS events(
 seq bigserial PRIMARY KEY, run_id text NOT NULL REFERENCES runs(id), kind text NOT NULL,
 payload jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS events_run ON events(run_id,seq);
CREATE TABLE IF NOT EXISTS calls(
 id text PRIMARY KEY, run_id text NOT NULL REFERENCES runs(id), kind text NOT NULL,
 request_hash text NOT NULL, request jsonb NOT NULL, status text NOT NULL,
 attempt text NOT NULL, fence bigint NOT NULL, response jsonb, error text NOT NULL DEFAULT '',
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS model_attempts(
 id text PRIMARY KEY, call_id text NOT NULL REFERENCES calls(id), status text NOT NULL,
 request jsonb NOT NULL, response jsonb, error text NOT NULL DEFAULT '',
 created_at timestamptz NOT NULL DEFAULT now(), finished_at timestamptz);
CREATE TABLE IF NOT EXISTS documents(
 id text PRIMARY KEY, kind text NOT NULL, title text NOT NULL, content text NOT NULL,
 source text NOT NULL, metadata jsonb NOT NULL, supersedes text REFERENCES documents(id),
 created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS artifacts(
 hash text PRIMARY KEY, body bytea NOT NULL, media_type text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS artifact_refs(
 root text NOT NULL, hash text NOT NULL REFERENCES artifacts(hash), PRIMARY KEY(root,hash));
CREATE TABLE IF NOT EXISTS instances(
 id text PRIMARY KEY, role text NOT NULL, hostname text NOT NULL, pid integer NOT NULL,
 heartbeat_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS sandbox_jobs(
 id text PRIMARY KEY, input_hash text NOT NULL, container_name text NOT NULL,
 status text NOT NULL, result jsonb, created_at timestamptz NOT NULL DEFAULT now());
INSERT INTO schema_versions(version) VALUES(1) ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS secrets(name text PRIMARY KEY, sealed bytea NOT NULL, updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS telemetry_exports(seq bigint PRIMARY KEY REFERENCES events(seq), exported_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE documents ADD COLUMN IF NOT EXISTS scope text NOT NULL DEFAULT '';
ALTER TABLE documents ADD COLUMN IF NOT EXISTS valid_until timestamptz;
INSERT INTO schema_versions(version) VALUES(2) ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS knowledge_files(
 id text PRIMARY KEY, kb_id text NOT NULL, kb_revision integer NOT NULL,
 document_id text NOT NULL REFERENCES documents(id), artifact_hash text NOT NULL REFERENCES artifacts(hash),
 name text NOT NULL, status text NOT NULL DEFAULT 'queued', error text NOT NULL DEFAULT '',
 track_id text NOT NULL DEFAULT '', config jsonb NOT NULL, receipt jsonb,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(kb_id,kb_revision,artifact_hash));
CREATE TABLE IF NOT EXISTS knowledge_chunks(
 id text PRIMARY KEY, file_id text NOT NULL REFERENCES knowledge_files(id), ordinal integer NOT NULL,
 content text NOT NULL, UNIQUE(file_id,ordinal));
CREATE TABLE IF NOT EXISTS business_runs(
 run_id text PRIMARY KEY REFERENCES runs(id), action_id text NOT NULL, action_revision integer NOT NULL,
 commodity text NOT NULL, created_at timestamptz NOT NULL DEFAULT now());
INSERT INTO schema_versions(version) VALUES(3) ON CONFLICT DO NOTHING;
CREATE UNIQUE INDEX IF NOT EXISTS knowledge_graph_endpoint ON resources((spec->>'endpoint')) WHERE kind='knowledge' AND spec->>'engine'='lightrag';
CREATE TABLE IF NOT EXISTS harness_exchanges(
 run_id text NOT NULL REFERENCES runs(id), seq integer NOT NULL, method text NOT NULL,
 input_hash text NOT NULL, request jsonb NOT NULL, rule_revision bigint NOT NULL,
 response jsonb, PRIMARY KEY(run_id,seq));
ALTER TABLE business_runs ADD COLUMN IF NOT EXISTS agent_id text;
ALTER TABLE business_runs ADD COLUMN IF NOT EXISTS agent_revision integer;
ALTER TABLE runs ADD COLUMN IF NOT EXISTS engine text NOT NULL DEFAULT 'legacy-go';
ALTER TABLE runs ALTER COLUMN engine SET DEFAULT 'dsh-0.2.0-rc.2';
CREATE TABLE IF NOT EXISTS app_runs(run_id text PRIMARY KEY REFERENCES runs(id),app text NOT NULL,metadata jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS app_runs_listing ON app_runs(app,created_at DESC);
INSERT INTO app_runs(run_id,app,metadata,created_at) SELECT run_id,'futures',jsonb_build_object('commodity',commodity),created_at FROM business_runs ON CONFLICT DO NOTHING;
ALTER TABLE knowledge_chunks ADD COLUMN IF NOT EXISTS search_vector tsvector;
CREATE INDEX IF NOT EXISTS knowledge_chunks_search ON knowledge_chunks USING gin(search_vector);
CREATE INDEX IF NOT EXISTS knowledge_chunks_search_pending ON knowledge_chunks(id) WHERE search_vector IS NULL;
