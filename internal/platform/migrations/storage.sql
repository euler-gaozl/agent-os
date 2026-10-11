CREATE TABLE IF NOT EXISTS documents(
 id text PRIMARY KEY, kind text NOT NULL, title text NOT NULL, content text NOT NULL,
 source text NOT NULL, metadata jsonb NOT NULL, supersedes text REFERENCES documents(id),
 created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS artifacts(
 hash text PRIMARY KEY, body bytea NOT NULL, media_type text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS artifact_refs(
 root text NOT NULL, hash text NOT NULL REFERENCES artifacts(hash), PRIMARY KEY(root,hash));
ALTER TABLE documents ADD COLUMN IF NOT EXISTS scope text NOT NULL DEFAULT '';
ALTER TABLE documents ADD COLUMN IF NOT EXISTS valid_until timestamptz;
