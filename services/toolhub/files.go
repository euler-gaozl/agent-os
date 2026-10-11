package toolhub

import (
	"context"
	"errors"
	"github.com/euler-gaozl/agent-os/internal/contracts"
)

func (s *Store) ReadSkillFile(ctx context.Context, run contracts.Run, id, path string, offset, limit int) (any, error) {
	if offset < 0 || limit < 0 || limit > 1200 {
		return nil, errors.New("invalid file window")
	}
	if limit == 0 {
		limit = 1200
	}
	var ref contracts.Ref
	for _, candidate := range run.Snapshot.Agent.Skills {
		if candidate.ID == id {
			ref = candidate
			break
		}
	}
	if ref.ID == "" {
		return nil, errors.New("skill not bound to run")
	}
	if _, e := s.Resolve(ctx, "skill", ref.ID, ref.Revision); e != nil {
		return nil, e
	}
	var hash string
	var body []byte
	if e := s.DB.QueryRow(ctx, "SELECT hash,body FROM asset_files WHERE kind='skill' AND id=$1 AND revision=$2 AND path=$3", id, ref.Revision, path).Scan(&hash, &body); e != nil {
		return nil, e
	}
	if hash != contracts.Hash(body) {
		return nil, errors.New("skill file hash mismatch")
	}
	chars := []rune(string(body))
	if offset > len(chars) {
		return nil, errors.New("offset exceeds file length")
	}
	end := min(offset+limit, len(chars))
	return map[string]any{"skill": ref, "path": path, "hash": hash, "content": string(chars[offset:end]), "next_offset": end, "has_more": end < len(chars)}, nil
}
