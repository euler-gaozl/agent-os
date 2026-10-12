package recordstore

import (
	"context"
	"errors"
	"regexp"

	. "github.com/euler-gaozl/agent-os/internal/contracts"
)

var RunRoot = regexp.MustCompile(`^run:[a-f0-9]{32}$`)
var ArtifactHash = regexp.MustCompile(`^[a-f0-9]{64}$`)

// Roots are computed by Runtime from its execution hierarchy, never accepted
// from a model or browser. Storage owns references but does not query runs.
type ArtifactPageRequest struct {
	Hash      string   `json:"hash"`
	Offset    int      `json:"offset"`
	Limit     int      `json:"limit"`
	Roots     []string `json:"roots"`
	AdoptRoot string   `json:"adopt_root"`
}

func (s *Store) ArtifactPage(ctx context.Context, in ArtifactPageRequest) (map[string]any, error) {
	if !ArtifactHash.MatchString(in.Hash) || !RunRoot.MatchString(in.AdoptRoot) || len(in.Roots) == 0 || len(in.Roots) > 128 || in.Offset < 0 || in.Limit < 0 || in.Limit > 1200 {
		return nil, errors.New("bounded artifact page and run roots required")
	}
	owned := false
	for _, root := range in.Roots {
		if !RunRoot.MatchString(root) {
			return nil, errors.New("invalid artifact visibility root")
		}
		owned = owned || root == in.AdoptRoot
	}
	if !owned {
		return nil, errors.New("adopt root must be within visible roots")
	}
	tx, e := s.DB.Begin(ctx)
	if e != nil {
		return nil, e
	}
	defer tx.Rollback(ctx)
	var body []byte
	var media string
	e = tx.QueryRow(ctx, `SELECT a.body,a.media_type FROM artifacts a WHERE a.hash=$1 AND EXISTS(
SELECT 1 FROM artifact_refs r WHERE r.hash=a.hash AND r.root=ANY($2)) FOR KEY SHARE OF a`, in.Hash, in.Roots).Scan(&body, &media)
	if e != nil {
		return nil, e
	}
	if Hash(body) != in.Hash {
		return nil, errors.New("artifact hash mismatch")
	}
	chars := []rune(string(body))
	if in.Offset > len(chars) {
		return nil, errors.New("offset exceeds artifact length")
	}
	if in.Limit == 0 {
		in.Limit = 1200
	}
	end := min(in.Offset+in.Limit, len(chars))
	if _, e = tx.Exec(ctx, "INSERT INTO artifact_refs(root,hash) VALUES($1,$2) ON CONFLICT DO NOTHING", in.AdoptRoot, in.Hash); e != nil {
		return nil, e
	}
	result := map[string]any{"hash": in.Hash, "media_type": media, "content": string(chars[in.Offset:end]), "total_characters": len(chars), "next_offset": end, "has_more": end < len(chars)}
	return result, tx.Commit(ctx)
}
