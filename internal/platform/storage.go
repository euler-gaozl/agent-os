package platform

import (
	"context"
	"errors"
	"github.com/euler-gaozl/agent-os/internal/recordstore"
	"github.com/jackc/pgx/v5"
)

var putDocument = recordstore.PutDocument
var putArtifact = recordstore.PutArtifact
var searchDocuments = searchNotes

func (s *Store) PutDocument(ctx context.Context, d Document) (Document, error) {
	return s.putAdminDocument(ctx, d, "runtime-internal")
}
func (s *Store) PutArtifact(ctx context.Context, b []byte, media, root string) (string, error) {
	if s.StorageURL != "" {
		if s.Remote == nil {
			return "", errors.New("artifact store client is not configured")
		}
		return s.Remote.PutArtifact(ctx, s.StorageURL, b, media, root)
	}
	return (&recordstore.Store{DB: s.DB}).SaveArtifact(ctx, b, media, root)
}
func (s *Store) Artifact(ctx context.Context, hash string) ([]byte, string, error) {
	return (&recordstore.Store{DB: s.DB}).Artifact(ctx, hash)
}
func (s *Store) Search(ctx context.Context, q, kind string) ([]Document, error) {
	return searchNotes(ctx, s.DB, q, kind)
}
func (s *Store) GC(ctx context.Context) (int64, error) { return (&recordstore.Store{DB: s.DB}).GC(ctx) }

var _ pgx.Tx
