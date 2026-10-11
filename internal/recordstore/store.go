package recordstore

import (
	"context"
	"encoding/json"
	"errors"
	. "github.com/euler-gaozl/agent-os/internal/contracts"
	"github.com/jackc/pgx/v5/pgxpool"
	"strings"

	"github.com/jackc/pgx/v5"
)

func PutDocument(ctx context.Context, tx pgx.Tx, d Document) (Document, error) {
	if !Has([]string{"knowledge", "memory", "evidence", "fact"}, d.Kind) || strings.TrimSpace(d.Title) == "" || strings.TrimSpace(d.Content) == "" || strings.TrimSpace(d.Source) == "" {
		return d, errors.New("kind, title, content and provenance source required")
	}
	if len(d.Content) > 1000000 {
		return d, errors.New("document exceeds 1 MB")
	}
	if d.ID == "" {
		d.ID = ID()
	}
	if d.Metadata == nil {
		d.Metadata = map[string]any{}
	}
	if d.Supersedes != nil {
		var previousKind, previousScope string
		if e := tx.QueryRow(ctx, "SELECT kind,scope FROM documents WHERE id=$1", *d.Supersedes).Scan(&previousKind, &previousScope); e != nil {
			return d, e
		}
		if previousKind != d.Kind || previousScope != d.Scope {
			return d, errors.New("revisions must preserve document kind and scope")
		}
	}
	_, e := tx.Exec(ctx, "INSERT INTO documents(id,kind,title,content,source,metadata,supersedes,scope,valid_until) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)", d.ID, d.Kind, d.Title, d.Content, d.Source, JSON(d.Metadata), d.Supersedes, d.Scope, d.ValidUntil)
	return d, e
}
func (s *Store) SaveDocument(ctx context.Context, d Document) (Document, error) {
	tx, e := s.DB.Begin(ctx)
	if e != nil {
		return d, e
	}
	defer tx.Rollback(ctx)
	d, e = PutDocument(ctx, tx, d)
	if e != nil {
		return d, e
	}
	return d, tx.Commit(ctx)
}

type querier interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
}

func SearchDocuments(ctx context.Context, q querier, query, kind string, scopes ...string) ([]Document, error) {
	scope := ""
	if len(scopes) > 0 {
		scope = scopes[0]
	}
	// Literal substring search works for Chinese as well as Latin text. No claim of semantic retrieval.
	pattern := "%" + strings.NewReplacer("\\", "\\\\", "%", "\\%", "_", "\\_").Replace(query) + "%"
	rows, e := q.Query(ctx, `SELECT d.id,d.kind,d.title,left(d.content,6000),d.source,d.metadata,d.supersedes,d.scope,d.valid_until,length(d.content)>6000 FROM documents d
 WHERE ($2='' OR d.kind=$2) AND (d.title ILIKE $1 OR d.content ILIKE $1)
 AND ($3='' OR d.scope='' OR d.scope=$3) AND (d.valid_until IS NULL OR d.valid_until>now())
 AND NOT EXISTS(SELECT 1 FROM documents newer WHERE newer.supersedes=d.id) ORDER BY d.created_at DESC LIMIT 30`, pattern, kind, scope)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []Document{}
	for rows.Next() {
		var d Document
		var m []byte
		if e = rows.Scan(&d.ID, &d.Kind, &d.Title, &d.Content, &d.Source, &m, &d.Supersedes, &d.Scope, &d.ValidUntil, &d.Truncated); e != nil {
			return nil, e
		}
		if e = json.Unmarshal(m, &d.Metadata); e != nil {
			return nil, e
		}
		out = append(out, d)
	}
	return out, rows.Err()
}
func (s *Store) Search(ctx context.Context, q, kind string) ([]Document, error) {
	return SearchDocuments(ctx, s.DB, q, kind)
}
func PutArtifact(ctx context.Context, tx pgx.Tx, body []byte, media, root string) (string, error) {
	if len(body) > 4<<20 || root == "" {
		return "", errors.New("artifact requires retention root and maximum 4 MiB")
	}
	hash := Hash(body)
	_, e := tx.Exec(ctx, "INSERT INTO artifacts(hash,body,media_type) VALUES($1,$2,$3) ON CONFLICT DO NOTHING", hash, body, media)
	if e != nil {
		return "", e
	}
	_, e = tx.Exec(ctx, "INSERT INTO artifact_refs(root,hash) VALUES($1,$2) ON CONFLICT DO NOTHING", root, hash)
	return hash, e
}
func (s *Store) SaveArtifact(ctx context.Context, body []byte, media, root string) (string, error) {
	tx, e := s.DB.Begin(ctx)
	if e != nil {
		return "", e
	}
	defer tx.Rollback(ctx)
	hash, e := PutArtifact(ctx, tx, body, media, root)
	if e != nil {
		return "", e
	}
	return hash, tx.Commit(ctx)
}
func (s *Store) Artifact(ctx context.Context, hash string) ([]byte, string, error) {
	var body []byte
	var media string
	e := s.DB.QueryRow(ctx, "SELECT body,media_type FROM artifacts WHERE hash=$1", hash).Scan(&body, &media)
	if e == nil && Hash(body) != hash {
		e = errors.New("artifact integrity check failed")
	}
	return body, media, e
}
func (s *Store) GC(ctx context.Context) (int64, error) {
	tag, e := s.DB.Exec(ctx, "DELETE FROM artifacts a WHERE a.created_at<now()-interval '24 hours' AND NOT EXISTS(SELECT 1 FROM artifact_refs r WHERE r.hash=a.hash)")
	return tag.RowsAffected(), e
}

type Store struct{ DB *pgxpool.Pool }
