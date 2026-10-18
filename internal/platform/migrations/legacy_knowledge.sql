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
ALTER TABLE knowledge_chunks ADD COLUMN IF NOT EXISTS search_vector tsvector;
CREATE INDEX IF NOT EXISTS knowledge_chunks_search ON knowledge_chunks USING gin(search_vector);
CREATE INDEX IF NOT EXISTS knowledge_chunks_search_pending ON knowledge_chunks(id) WHERE search_vector IS NULL;
ALTER TABLE knowledge_files ADD COLUMN IF NOT EXISTS name_vector tsvector;
CREATE INDEX IF NOT EXISTS knowledge_files_name_search ON knowledge_files USING gin(name_vector);
CREATE INDEX IF NOT EXISTS knowledge_files_name_pending ON knowledge_files(id) WHERE name_vector IS NULL;
