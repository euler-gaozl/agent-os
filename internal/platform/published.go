package platform

import (
	"encoding/json"
	"errors"
	"net/http"
)

func (s *Server) publishedRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/published/{app}", wrap(func(w http.ResponseWriter, r *http.Request) error {
		rows, e := s.Store.DB.Query(r.Context(), "SELECT id,revision,spec FROM resources a WHERE kind='agent' AND revision=(SELECT max(revision) FROM resources b WHERE b.kind=a.kind AND b.id=a.id) AND spec#>>'{publication,enabled}'='true' AND spec#>>'{publication,app}'=$1 ORDER BY id LIMIT 200", r.PathValue("app"))
		if e != nil {
			return e
		}
		defer rows.Close()
		out := []any{}
		for rows.Next() {
			var id string
			var rev int
			var raw []byte
			var a Agent
			if e = rows.Scan(&id, &rev, &raw); e != nil {
				return e
			}
			if e = json.Unmarshal(raw, &a); e != nil {
				return e
			}
			out = append(out, map[string]any{"id": id, "revision": rev, "name": a.Publication.Name, "description": a.Publication.Description})
		}
		if e = rows.Err(); e != nil {
			return e
		}
		jsonResponse(w, 200, out)
		return nil
	}))
	mux.HandleFunc("GET /v1/published/{app}/{id}", wrap(func(w http.ResponseWriter, r *http.Request) error {
		var v Resource
		if e := s.Store.DB.QueryRow(r.Context(), "SELECT kind,id,revision,spec FROM resources WHERE kind='agent' AND id=$1 ORDER BY revision DESC LIMIT 1", r.PathValue("id")).Scan(&v.Kind, &v.ID, &v.Revision, &v.Spec); e != nil {
			return e
		}
		var a Agent
		if e := json.Unmarshal(v.Spec, &a); e != nil {
			return e
		}
		if !a.Publication.Enabled || a.Publication.App != r.PathValue("app") {
			return errors.New("agent is unpublished")
		}
		jsonResponse(w, 200, v)
		return nil
	}))
}
