package platform

import (
	"context"
	"github.com/euler-gaozl/agent-os/internal/recordstore"
	"github.com/jackc/pgx/v5"
)

var putDocument = recordstore.PutDocument
var putArtifact = recordstore.PutArtifact
var searchDocuments = recordstore.SearchDocuments

func (s *Store) PutDocument(ctx context.Context, d Document) (Document, error) {
	return (&recordstore.Store{DB: s.DB}).SaveDocument(ctx, d)
}
func (s *Store) PutArtifact(ctx context.Context, b []byte, media, root string) (string, error) {
	return (&recordstore.Store{DB: s.DB}).SaveArtifact(ctx, b, media, root)
}
func (s *Store) Artifact(ctx context.Context, hash string) ([]byte, string, error) {
	return (&recordstore.Store{DB: s.DB}).Artifact(ctx, hash)
}
func (s *Store) Search(ctx context.Context, q, kind string) ([]Document, error) {
	return (&recordstore.Store{DB: s.DB}).Search(ctx, q, kind)
}
func (s *Store) GC(ctx context.Context) (int64, error) { return (&recordstore.Store{DB: s.DB}).GC(ctx) }

var _ pgx.Tx
