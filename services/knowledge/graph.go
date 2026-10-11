package knowledge

import (
	"context"
	"encoding/json"
	"errors"
	. "github.com/euler-gaozl/agent-os/internal/contracts"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

var graphFileID = regexp.MustCompile(`^[a-f0-9]{32}-`)

type graphSource struct {
	ID     string `json:"document_id"`
	Title  string `json:"title"`
	Source string `json:"source"`
}

// The remote graph is a derived, untrusted index. Only provenance belonging to
// ready documents in this exact KB revision may enter the model context. In
// particular, a merged entity mentioning both owned and foreign files is not
// safe just because ONE of its source files is authorized.
func (s *Store) scopedGraph(ctx context.Context, ref Ref, endpoint string, body []byte) (json.RawMessage, error) {
	var data struct {
		Entities      []map[string]json.RawMessage `json:"entities"`
		Relationships []map[string]json.RawMessage `json:"relationships"`
		Chunks        []map[string]json.RawMessage `json:"chunks"`
	}
	if e := json.Unmarshal(body, &data); e != nil {
		return nil, e
	}
	if len(data.Entities) > 32 || len(data.Relationships) > 32 || len(data.Chunks) > 8 {
		return nil, errors.New("LightRAG result exceeds bounded context limits")
	}
	groups := [][]map[string]json.RawMessage{data.Entities, data.Relationships, data.Chunks}
	text := func(item map[string]json.RawMessage, key string) string {
		var v string
		if json.Unmarshal(item[key], &v) != nil {
			return ""
		}
		return v
	}
	paths := map[string]bool{}
	ids := []string{}
	for _, items := range groups {
		for _, item := range items {
			for _, p := range strings.Split(text(item, "file_path"), "<SEP>") {
				p = strings.TrimSpace(p)
				if len(p) <= 512 && graphFileID.MatchString(p) && !paths[p] {
					paths[p] = true
					ids = append(ids, p[:32])
				}
			}
		}
	}
	if len(ids) > 128 {
		return nil, errors.New("LightRAG source count exceeds limit")
	}
	owned := map[string]graphSource{}
	if len(ids) > 0 {
		rows, e := s.DB.Query(ctx, `SELECT f.id,f.name,d.id,d.title,d.source FROM knowledge_files f JOIN documents d ON d.id=f.document_id WHERE f.id=ANY($1) AND f.kb_id=$2 AND f.kb_revision=$3 AND f.status='ready' AND f.config->>'engine'='lightrag' AND rtrim(f.config->>'endpoint','/')=rtrim($4,'/')`, ids, ref.ID, ref.Revision, endpoint)
		if e != nil {
			return nil, e
		}
		for rows.Next() {
			var id, name string
			var source graphSource
			if e = rows.Scan(&id, &name, &source.ID, &source.Title, &source.Source); e != nil {
				rows.Close()
				return nil, e
			}
			owned[id+"-"+filepath.Base(name)] = source
		}
		e = rows.Err()
		rows.Close()
		if e != nil {
			return nil, e
		}
	}
	fields := [][]string{{"entity_name", "entity_type", "description"}, {"src_id", "tgt_id", "description", "keywords"}, {"content"}}
	names := []string{"entities", "relationships", "chunks"}
	result := map[string]any{}
	references := map[string]graphSource{}
	discarded := 0
	for kind, items := range groups {
		clean := []map[string]any{}
		for _, item := range items {
			sources := []graphSource{}
			valid := true
			seen := map[string]bool{}
			for _, p := range strings.Split(text(item, "file_path"), "<SEP>") {
				source, ok := owned[strings.TrimSpace(p)]
				if !ok {
					valid = false
					break
				}
				if !seen[source.ID] {
					sources = append(sources, source)
					seen[source.ID] = true
				}
			}
			out := map[string]any{}
			for _, key := range fields[kind] {
				v := text(item, key)
				if len(v) > 8000 {
					valid = false
					break
				}
				out[key] = v
			}
			if kind == 2 && valid {
				// A chunk is evidence only when it is literally present in its
				// retained source. Do not echo invented/foreign remote text.
				content := text(item, "content")
				if content == "" || len(sources) != 1 {
					valid = false
				} else {
					var matches bool
					e := s.DB.QueryRow(ctx, "SELECT strpos(content,$2)>0 FROM documents WHERE id=$1", sources[0].ID, content).Scan(&matches)
					if e != nil {
						return nil, e
					}
					valid = matches
				}
			}
			if !valid {
				discarded++
				continue
			}
			out["sources"] = sources
			for _, source := range sources {
				references[source.ID] = source
			}
			clean = append(clean, out)
		}
		result[names[kind]] = clean
	}
	ordered := make([]graphSource, 0, len(references))
	for _, source := range references {
		ordered = append(ordered, source)
	}
	sort.Slice(ordered, func(i, j int) bool { return ordered[i].ID < ordered[j].ID })
	result["references"] = ordered
	result["discarded_items"] = discarded
	result["notice"] = "Graph entities and relationships are extracted claims, not verified facts. Read the retained source documents to verify them."
	out := JSON(result)
	if len(out) > 128<<10 {
		return nil, errors.New("LightRAG context exceeds 128 KiB")
	}
	return out, nil
}
