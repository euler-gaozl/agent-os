package knowledge

import (
	"context"
	"encoding/json"
	"github.com/euler-gaozl/agent-os/internal/contracts"
	"github.com/jackc/pgx/v5"
	"strings"
	"unicode"
)

// SearchText produces deterministic lexical tokens without a resident tokenizer
// model. Han bigrams support Chinese phrases; Latin/digit words stay intact.
// This is lexical retrieval, not semantic understanding or Chinese word parsing.
func SearchText(text string) string {
	runes := []rune(strings.ToLower(text))
	seen := map[string]bool{}
	tokens := []string{}
	add := func(s string) {
		if s != "" && !seen[s] {
			seen[s] = true
			tokens = append(tokens, s)
		}
	}
	for i := 0; i < len(runes); {
		if unicode.Is(unicode.Han, runes[i]) {
			if i+1 < len(runes) && unicode.Is(unicode.Han, runes[i+1]) {
				add(string(runes[i : i+2]))
			}
			i++
			continue
		}
		if unicode.IsLetter(runes[i]) || unicode.IsDigit(runes[i]) {
			start := i
			for i < len(runes) && !unicode.Is(unicode.Han, runes[i]) && (unicode.IsLetter(runes[i]) || unicode.IsDigit(runes[i])) {
				i++
			}
			add(string(runes[start:i]))
			continue
		}
		i++
	}
	return strings.Join(tokens, " ")
}
func scopeToken(ref contracts.Ref) string { return "scope" + contracts.Hash(contracts.JSON(ref))[:24] }

// Scope is part of the indexed query, then checked against authoritative file
// metadata again. Materializing a bounded candidate set prevents PostgreSQL's
// generic prepared plan from choosing a file-first nested scan under LIMIT.
// This remains bounded lexical retrieval, not relevance-ranked full recall.
const localChunkQuery = `WITH candidates AS MATERIALIZED (
 SELECT id,file_id,content FROM knowledge_chunks WHERE search_vector @@ plainto_tsquery('simple',$3) LIMIT 64
) SELECT c.id,c.content,d.source,d.id,f.name FROM candidates c
 JOIN knowledge_files f ON f.id=c.file_id JOIN documents d ON d.id=f.document_id
 WHERE f.kb_id=$1 AND f.kb_revision=$2 AND f.status='ready' LIMIT 8`
// Plan the indexed filename predicate independently of LIMIT. Combining the two
// caused an optimistic sequential scan for absent terms at one million files.
// The second materialization still bounds rows consumed by the joins to 64.
const localNameQuery = `WITH matches AS MATERIALIZED (
 SELECT id,name,document_id,kb_id,kb_revision,status FROM knowledge_files WHERE name_vector @@ plainto_tsquery('simple',$3)
), candidates AS MATERIALIZED (
 SELECT * FROM matches LIMIT 64
) SELECT c.id,c.content,d.source,d.id,f.name FROM candidates f
 JOIN documents d ON d.id=f.document_id JOIN knowledge_chunks c ON c.file_id=f.id AND c.ordinal=0
 WHERE f.kb_id=$1 AND f.kb_revision=$2 AND f.status='ready' LIMIT 8`

// ExplainLocal is used by the disposable capacity runner, never by model tools.
func (s *Store) ExplainLocal(ctx context.Context, ref contracts.Ref, query string) (map[string]any, error) {
	out := map[string]any{}
	for name, sql := range map[string]string{"chunks": localChunkQuery, "names": localNameQuery} {
		var plan []byte
		if e := s.DB.QueryRow(ctx, "EXPLAIN (FORMAT JSON) "+sql, ref.ID, ref.Revision, scopeToken(ref)+" "+SearchText(query)).Scan(&plan); e != nil {
			return nil, e
		}
		var decoded any
		if e := json.Unmarshal(plan, &decoded); e != nil {
			return nil, e
		}
		out[name] = decoded
	}
	return out, nil
}
func (s *Store) IndexNamesBatch(ctx context.Context) (int, error) {
	tx, e := s.DB.Begin(ctx)
	if e != nil {
		return 0, e
	}
	defer tx.Rollback(ctx)
	rows, e := tx.Query(ctx, "SELECT id,name,kb_id,kb_revision FROM knowledge_files WHERE name_vector IS NULL ORDER BY id FOR UPDATE SKIP LOCKED LIMIT 128")
	if e != nil {
		return 0, e
	}
	batch := &pgx.Batch{}
	n := 0
	for rows.Next() {
		var id, name string
		var ref contracts.Ref
		if e = rows.Scan(&id, &name, &ref.ID, &ref.Revision); e != nil {
			rows.Close()
			return 0, e
		}
		batch.Queue("UPDATE knowledge_files SET name_vector=to_tsvector('simple',$2) WHERE id=$1", id, scopeToken(ref)+" "+SearchText(name))
		n++
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return 0, e
	}
	if n > 0 {
		if e = tx.SendBatch(ctx, batch).Close(); e != nil {
			return 0, e
		}
	}
	return n, tx.Commit(ctx)
}
func (s *Store) IndexLocalBatch(ctx context.Context) (int, error) {
	tx, e := s.DB.Begin(ctx)
	if e != nil {
		return 0, e
	}
	defer tx.Rollback(ctx)
	rows, e := tx.Query(ctx, "SELECT c.id,c.content,f.kb_id,f.kb_revision FROM knowledge_chunks c JOIN knowledge_files f ON f.id=c.file_id WHERE c.search_vector IS NULL ORDER BY c.id FOR UPDATE OF c SKIP LOCKED LIMIT 128")
	if e != nil {
		return 0, e
	}
	batch := &pgx.Batch{}
	n := 0
	for rows.Next() {
		var id, text string
		var ref contracts.Ref
		if e = rows.Scan(&id, &text, &ref.ID, &ref.Revision); e != nil {
			rows.Close()
			return 0, e
		}
		batch.Queue("UPDATE knowledge_chunks SET search_vector=to_tsvector('simple',$2) WHERE id=$1", id, scopeToken(ref)+" "+SearchText(text))
		n++
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return 0, e
	}
	if n > 0 {
		results := tx.SendBatch(ctx, batch)
		if e = results.Close(); e != nil {
			return 0, e
		}
	}
	return n, tx.Commit(ctx)
}
