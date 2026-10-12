// Package storage owns immutable artifacts and retention references. It has no
// execution-table dependency; Runtime supplies authorized artifact roots.
package storage

import (
	"errors"
	"io"
	"net/http"

	. "github.com/euler-gaozl/agent-os/internal/contracts"
	"github.com/euler-gaozl/agent-os/internal/recordstore"
	"github.com/euler-gaozl/agent-os/internal/servicehttp"
)

type Server struct {
	Store *recordstore.Store
	HTTP  servicehttp.Config
}

func (s *Server) Handler() http.Handler { return servicehttp.New(s.HTTP, s.Store.DB.Ping, s.routes) }
func (s *Server) routes(m *http.ServeMux) {
	m.HandleFunc("PUT /v1/artifacts/{hash}", servicehttp.Wrap(func(w http.ResponseWriter, r *http.Request) error {
		hash, root, media := r.PathValue("hash"), r.Header.Get("X-Artifact-Root"), r.Header.Get("X-Artifact-Media-Type")
		if !recordstore.ArtifactHash.MatchString(hash) || !recordstore.RunRoot.MatchString(root) || len(media) == 0 || len(media) > 200 {
			return errors.New("artifact hash, run retention root and media type required")
		}
		body, e := io.ReadAll(http.MaxBytesReader(w, r.Body, 4<<20))
		if e != nil {
			return &servicehttp.StatusError{Status: 413, Message: "artifact exceeds 4 MiB"}
		}
		if Hash(body) != hash {
			return errors.New("artifact content does not match hash")
		}
		stored, e := s.Store.SaveArtifact(r.Context(), body, media, root)
		if e != nil {
			return e
		}
		servicehttp.JSONResponse(w, 200, map[string]string{"hash": stored})
		return nil
	}))
	m.HandleFunc("POST /v1/artifacts/page", servicehttp.Wrap(func(w http.ResponseWriter, r *http.Request) error {
		var in recordstore.ArtifactPageRequest
		if e := servicehttp.Decode(w, r, &in); e != nil {
			return e
		}
		result, e := s.Store.ArtifactPage(r.Context(), in)
		if e != nil {
			return e
		}
		servicehttp.JSONResponse(w, 200, result)
		return nil
	}))
	m.HandleFunc("GET /artifacts/{hash}", servicehttp.Wrap(func(w http.ResponseWriter, r *http.Request) error {
		if !recordstore.ArtifactHash.MatchString(r.PathValue("hash")) {
			return errors.New("invalid artifact hash")
		}
		b, media, e := s.Store.Artifact(r.Context(), r.PathValue("hash"))
		if e != nil {
			return e
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Disposition", "attachment; filename=\""+r.PathValue("hash")+"\"")
		w.Header().Set("X-Artifact-Media-Type", media)
		_, e = w.Write(b)
		return e
	}))
	m.HandleFunc("POST /gc", servicehttp.Wrap(func(w http.ResponseWriter, r *http.Request) error {
		n, e := s.Store.GC(r.Context())
		if e != nil {
			return e
		}
		servicehttp.JSONResponse(w, 200, map[string]int64{"deleted": n})
		return nil
	}))
}
