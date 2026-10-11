package knowledge

import (
	"context"
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
