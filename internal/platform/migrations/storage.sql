CREATE TABLE IF NOT EXISTS artifacts(
 hash text PRIMARY KEY, body bytea NOT NULL, media_type text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS artifact_refs(
 root text NOT NULL, hash text NOT NULL REFERENCES artifacts(hash), PRIMARY KEY(root,hash));
