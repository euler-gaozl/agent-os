package platform

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/euler-gaozl/agent-os/internal/catalog"
	"github.com/euler-gaozl/agent-os/internal/servicehttp"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

type Server struct {
	Store                                                   *Store
	Role, Token, AdminToken, StorageURL, SandboxURL, WebDir string
	DevLocal                                                bool
	RegistryURL, RuntimeURL, KnowledgeURL                   string
}
type handler func(http.ResponseWriter, *http.Request) error

func jsonResponse(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func decode(w http.ResponseWriter, r *http.Request, dst any) error {
	r.Body = http.MaxBytesReader(w, r.Body, 2<<20)
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if e := d.Decode(dst); e != nil {
		return e
	}
	var extra any
	if e := d.Decode(&extra); e != io.EOF {
		return errors.New("expected exactly one JSON value")
	}
	return nil
}
func wrap(h handler) http.HandlerFunc {
	return servicehttp.Wrap(h)
}
func (s *Server) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Cache-Control", "no-store")
		if r.URL.Path == "/healthz" {
			next.ServeHTTP(w, r)
			return
		}
		expected := s.Token
		if s.Role == "control" || s.Role == "futures" {
			expected = s.AdminToken
		}
		provided := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		ok := len(expected) >= 32 && subtle.ConstantTimeCompare([]byte(provided), []byte(expected)) == 1
		if !ok && (s.Role == "control" || s.Role == "futures") && s.DevLocal {
			peer, _, _ := net.SplitHostPort(r.RemoteAddr)
			host, _, e := net.SplitHostPort(r.Host)
			if e != nil {
				host = r.Host
			}
			origin := r.Header.Get("Origin")
			localHost := host == "127.0.0.1" || host == "localhost" || host == "[::1]" || host == "::1"
			originOK := origin == "" || origin == "http://"+r.Host
			ip := net.ParseIP(peer)
			ok = ip != nil && ip.IsLoopback() && localHost && originOK
			if r.Method != "GET" && r.Method != "HEAD" {
				ok = ok && r.Header.Get("X-AgentOS-Client") == "web"
			}
		}
		// Static UI contains no secrets and still requires an API session for data in non-local deployments.
		if (s.Role == "control" || s.Role == "futures") && !strings.HasPrefix(r.URL.Path, "/api/") {
			ok = true
		}
		if !ok {
			jsonResponse(w, 401, map[string]string{"error": "authentication required"})
			return
		}
		next.ServeHTTP(w, r)
	})
}
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		jsonResponse(w, 200, map[string]string{"role": s.Role, "status": "alive"})
	})
	mux.HandleFunc("GET /readyz", wrap(func(w http.ResponseWriter, r *http.Request) error {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if e := s.Store.DB.Ping(ctx); e != nil {
			return e
		}
		jsonResponse(w, 200, map[string]bool{"ready": true})
		return nil
	}))
	switch s.Role {
	case "control":
		s.controlRoutes(mux)
	case "toolhub":
		s.toolRoutes(mux)
	case "storage":
		s.storageRoutes(mux)
	case "sandbox":
		s.sandboxRoutes(mux)
	case "registry":
		s.registryRoutes(mux)
	case "runtime":
		s.runtimeRoutes(mux)
		s.toolRoutes(mux)
	case "knowledge":
		s.knowledgeRoutes(mux)
	case "futures":
		s.futuresRoutes(mux)
	}
	return s.auth(mux)
}
func (s *Server) controlRoutes(mux *http.ServeMux) {
	for _, path := range []string{"/api/resources", "/api/credentials", "/api/connectors/discover"} {
		mux.HandleFunc(path, func(w http.ResponseWriter, r *http.Request) {
			s.proxy(w, r, s.RegistryURL+strings.Replace(r.URL.Path, "/api/", "/v1/", 1))
		})
	}
	for _, path := range []string{"/api/runs", "/api/runs/"} {
		mux.HandleFunc(path, func(w http.ResponseWriter, r *http.Request) {
			s.proxy(w, r, s.RuntimeURL+strings.Replace(r.URL.Path, "/api/", "/v1/", 1))
		})
	}
	for _, path := range []string{"/api/knowledge/"} {
		mux.HandleFunc(path, func(w http.ResponseWriter, r *http.Request) {
			s.proxy(w, r, s.KnowledgeURL+strings.Replace(r.URL.Path, "/api/knowledge/", "/v1/", 1))
		})
	}
	mux.HandleFunc("GET /api/status", wrap(func(w http.ResponseWriter, r *http.Request) error {
		rows, e := s.Store.DB.Query(r.Context(), "SELECT id,role,hostname,pid,heartbeat_at,heartbeat_at>now()-interval '15 seconds' FROM instances ORDER BY role,id")
		if e != nil {
			return e
		}
		defer rows.Close()
		out := []any{}
		for rows.Next() {
			var id, role, host string
			var pid int
			var at time.Time
			var active bool
			if e = rows.Scan(&id, &role, &host, &pid, &at, &active); e != nil {
				return e
			}
			out = append(out, map[string]any{"id": id, "role": role, "hostname": host, "pid": pid, "heartbeat_at": at, "active": active})
		}
		if e = rows.Err(); e != nil {
			return e
		}
		_, keyErr := s.Store.Secret(r.Context(), "DEEPSEEK_API_KEY")
		jsonResponse(w, 200, map[string]any{"instances": out, "deepseek_configured": keyErr == nil, "local_mode": s.DevLocal, "version": "0.3.0"})
		return nil
	}))
	mux.HandleFunc("/api/documents", func(w http.ResponseWriter, r *http.Request) { s.proxy(w, r, s.StorageURL+"/documents") })
	mux.HandleFunc("GET /api/documents/{id}", func(w http.ResponseWriter, r *http.Request) {
		s.proxy(w, r, s.StorageURL+"/documents/"+url.PathEscape(r.PathValue("id")))
	})
	mux.HandleFunc("/api/artifacts/{hash}", func(w http.ResponseWriter, r *http.Request) {
		s.proxy(w, r, s.StorageURL+"/artifacts/"+url.PathEscape(r.PathValue("hash")))
	})
	if s.WebDir != "" {
		mux.Handle("/", http.FileServer(http.Dir(s.WebDir)))
	}
}
func (s *Server) toolRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /invoke", wrap(func(w http.ResponseWriter, r *http.Request) error {
		var inv Invocation
		if e := decode(w, r, &inv); e != nil {
			return e
		}
		if inv.OperationID == "" || !strings.HasPrefix(inv.OperationID, inv.RunID+"/") {
			return errors.New("operation id must be scoped to run")
		}
		// Recheck governance even for direct Runtime calls. Never trust the
		// worker's saved snapshot as authorization for a withdrawn asset.
		if s.Store.Remote != nil {
			run, err := s.Store.Run(r.Context(), inv.RunID)
			if err != nil {
				return err
			}
			for _, ref := range run.Snapshot.Agent.Skills {
				var v Skill
				if err = s.Store.Resource(r.Context(), "skill", ref, &v); err != nil {
					return err
				}
			}
			for _, ref := range run.Snapshot.Agent.Connectors {
				var v Connector
				if err = s.Store.Resource(r.Context(), "connector", ref, &v); err != nil {
					return err
				}
			}
		}
		remoteDocument := false
		if inv.Name == "document_read" && s.Store.Remote != nil {
			var args struct{ ID string }
			if e := json.Unmarshal(inv.Arguments, &args); e != nil {
				return e
			}
			var local bool
			if e := s.Store.DB.QueryRow(r.Context(), "SELECT EXISTS(SELECT 1 FROM documents d JOIN runs r ON r.id=$2 WHERE d.id=$1 AND (d.scope='' OR d.scope=r.snapshot->'agent_ref'->>'id'))", args.ID, inv.RunID).Scan(&local); e != nil {
				return e
			}
			remoteDocument = !local
		}
		var result []byte
		var e error
		if strings.HasPrefix(inv.Name, "mcp_") || inv.Name == "sandbox_exec" || inv.Name == "kb_search" || inv.Name == "skill_file_read" || remoteDocument {
			result, e = s.Store.ExternalTool(r.Context(), inv, func(ctx context.Context, run Run) ([]byte, error) {
				if inv.Name == "skill_file_read" {
					var args map[string]any
					if e := json.Unmarshal(inv.Arguments, &args); e != nil {
						return nil, e
					}
					args["run_id"] = run.ID
					return internalRequest(ctx, s.Store.CatalogURL+"/v1/skill-file", s.Token, args)
				}
				if remoteDocument {
					var args map[string]any
					if e := json.Unmarshal(inv.Arguments, &args); e != nil {
						return nil, e
					}
					args["run_id"] = run.ID
					return internalRequest(ctx, s.KnowledgeURL+"/v1/document", s.Token, args)
				}
				if inv.Name == "kb_search" {
					var args map[string]any
					if e := json.Unmarshal(inv.Arguments, &args); e != nil {
						return nil, e
					}
					args["run_id"] = run.ID
					return internalRequest(ctx, s.KnowledgeURL+"/v1/retrieve", s.Token, args)
				}
				if inv.Name == "sandbox_exec" {
					return internalRequest(ctx, s.SandboxURL+"/execute", s.Token, inv)
				}
				if c, name, found := connectorForTool(run.Snapshot, inv.Name); found {
					var e error
					c.AuthToken, e = s.Store.Secret(ctx, c.KeyEnv)
					if e != nil {
						return nil, e
					}
					return executeCheckedMCP(ctx, c, name, inv.Arguments)
				}
				return nil, errors.New("connector missing")
			})
		} else {
			result, e = s.Store.LocalTool(r.Context(), inv)
		}
		if e != nil {
			return e
		}
		w.Header().Set("Content-Type", "application/json")
		_, e = w.Write(result)
		return e
	}))
}
func (s *Server) storageRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /documents/{id}", wrap(func(w http.ResponseWriter, r *http.Request) error {
		var d Document
		var metadata []byte
		e := s.Store.DB.QueryRow(r.Context(), "SELECT id,kind,title,content,source,metadata,supersedes,scope,valid_until FROM documents WHERE id=$1", r.PathValue("id")).Scan(&d.ID, &d.Kind, &d.Title, &d.Content, &d.Source, &metadata, &d.Supersedes, &d.Scope, &d.ValidUntil)
		if e != nil {
			return e
		}
		if e = json.Unmarshal(metadata, &d.Metadata); e != nil {
			return e
		}
		jsonResponse(w, 200, d)
		return nil
	}))
	mux.HandleFunc("GET /documents", wrap(func(w http.ResponseWriter, r *http.Request) error {
		v, e := s.Store.Search(r.Context(), r.URL.Query().Get("q"), r.URL.Query().Get("kind"))
		if e != nil {
			return e
		}
		jsonResponse(w, 200, v)
		return nil
	}))
	mux.HandleFunc("POST /documents", wrap(func(w http.ResponseWriter, r *http.Request) error {
		var d Document
		if e := decode(w, r, &d); e != nil {
			return e
		}
		v, e := s.Store.PutDocument(r.Context(), d)
		if e != nil {
			return e
		}
		jsonResponse(w, 201, v)
		return nil
	}))
	mux.HandleFunc("GET /artifacts/{hash}", wrap(func(w http.ResponseWriter, r *http.Request) error {
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
	mux.HandleFunc("POST /gc", wrap(func(w http.ResponseWriter, r *http.Request) error {
		n, e := s.Store.GC(r.Context())
		if e != nil {
			return e
		}
		jsonResponse(w, 200, map[string]int64{"deleted": n})
		return nil
	}))
}
func internalRequest(ctx context.Context, endpoint, token string, v any) ([]byte, error) {
	req, e := http.NewRequestWithContext(ctx, "POST", endpoint, bytes.NewReader(JSON(v)))
	if e != nil {
		return nil, e
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	resp, e := externalHTTP.Do(req)
	if e != nil {
		return nil, e
	}
	defer resp.Body.Close()
	body, e := io.ReadAll(io.LimitReader(resp.Body, 4<<20+1))
	if e != nil {
		return nil, e
	}
	if len(body) > 4<<20 {
		return nil, errors.New("internal response too large")
	}
	if resp.StatusCode == 409 {
		return nil, ErrUnknown
	}
	if resp.StatusCode == 412 {
		return nil, ErrFence
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("service HTTP %d: %s", resp.StatusCode, truncateUTF8(string(body), 500))
	}
	return body, nil
}
func (s *Server) proxy(w http.ResponseWriter, r *http.Request, target string) {
	if r.URL.RawQuery != "" {
		target += "?" + r.URL.RawQuery
	}
	req, e := http.NewRequestWithContext(r.Context(), r.Method, target, http.MaxBytesReader(w, r.Body, 2<<20))
	if e != nil {
		jsonResponse(w, 502, map[string]string{"error": e.Error()})
		return
	}
	req.Header.Set("Authorization", "Bearer "+s.Token)
	req.Header.Set("Content-Type", "application/json")
	if key := r.Header.Get("Idempotency-Key"); key != "" {
		req.Header.Set("Idempotency-Key", key)
	}
	resp, e := externalHTTP.Do(req)
	if e != nil {
		jsonResponse(w, 502, map[string]string{"error": "upstream service unavailable"})
		return
	}
	defer resp.Body.Close()
	for _, name := range []string{"Content-Type", "Content-Disposition", "X-Artifact-Media-Type"} {
		w.Header().Set(name, resp.Header.Get(name))
	}
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, io.LimitReader(resp.Body, 4<<20))
}
func RegisterInstance(ctx context.Context, s *Store, id, role string) {
	host, _ := os.Hostname()
	update := func() {
		_, e := s.DB.Exec(ctx, `INSERT INTO instances(id,role,hostname,pid) VALUES($1,$2,$3,$4) ON CONFLICT(id) DO UPDATE SET heartbeat_at=now(),pid=$4`, id, role, host, os.Getpid())
		if e != nil && ctx.Err() == nil {
			slog.Warn("instance heartbeat failed", "error", e)
		}
	}
	update()
	t := time.NewTicker(4 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			update()
		}
	}
}

func (s *Server) registryRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/catalog", wrap(func(w http.ResponseWriter, r *http.Request) error {
		q, e := catalog.Parse(r.URL.Query())
		if e != nil {
			return e
		}
		page, e := s.Store.Catalog(r.Context(), q)
		if e != nil {
			return e
		}
		jsonResponse(w, 200, page)
		return nil
	}))
	mux.HandleFunc("GET /v1/status", wrap(func(w http.ResponseWriter, r *http.Request) error {
		_, e := s.Store.Secret(r.Context(), "DEEPSEEK_API_KEY")
		jsonResponse(w, 200, map[string]bool{"deepseek_configured": e == nil})
		return nil
	}))
	mux.HandleFunc("GET /v1/resources/{kind}/{id}/{revision}", wrap(func(w http.ResponseWriter, r *http.Request) error {
		rev, e := strconv.Atoi(r.PathValue("revision"))
		if e != nil {
			return e
		}
		var spec json.RawMessage
		if e = s.Store.Resource(r.Context(), r.PathValue("kind"), Ref{ID: r.PathValue("id"), Revision: rev}, &spec); e != nil {
			return e
		}
		jsonResponse(w, 200, Resource{Kind: r.PathValue("kind"), ID: r.PathValue("id"), Revision: rev, Spec: spec})
		return nil
	}))
	mux.HandleFunc("POST /v1/credentials/resolve", wrap(func(w http.ResponseWriter, r *http.Request) error {
		var in struct {
			Name string `json:"name"`
		}
		if e := decode(w, r, &in); e != nil {
			return e
		}
		value, e := s.Store.Secret(r.Context(), in.Name)
		if e != nil {
			return e
		}
		jsonResponse(w, 200, map[string]string{"value": value})
		return nil
	}))
	mux.HandleFunc("POST /v1/credentials", wrap(func(w http.ResponseWriter, r *http.Request) error {
		var in struct {
			Name  string `json:"name"`
			Value string `json:"value"`
		}
		if e := decode(w, r, &in); e != nil {
			return e
		}
		if e := s.Store.PutSecret(r.Context(), in.Name, in.Value); e != nil {
			return e
		}
		jsonResponse(w, 200, map[string]bool{"saved": true})
		return nil
	}))
	mux.HandleFunc("GET /v1/resources", wrap(func(w http.ResponseWriter, r *http.Request) error {
		v, e := s.Store.Resources(r.Context(), r.URL.Query().Get("after"))
		if e != nil {
			return e
		}
		visible := []Resource{}
		for _, item := range v {
			if item.Kind != "action" {
				visible = append(visible, item)
			}
		}
		jsonResponse(w, 200, visible)
		return nil
	}))
	mux.HandleFunc("POST /v1/resources", wrap(func(w http.ResponseWriter, r *http.Request) error {
		var in struct {
			Kind, ID string
			Spec     json.RawMessage
		}
		if e := decode(w, r, &in); e != nil {
			return e
		}
		if !safeName.MatchString(in.ID) || !Has([]string{"agent", "skill", "prompt", "connector", "knowledge"}, in.Kind) {
			return errors.New("invalid resource kind or id")
		}
		switch in.Kind {
		case "knowledge":
			var kb KnowledgeBase
			if e := json.Unmarshal(in.Spec, &kb); e != nil {
				return e
			}
			if e := kb.Validate(); e != nil {
				return e
			}
			if kb.Engine == "lightrag" {
				var count int
				if e := s.Store.DB.QueryRow(r.Context(), "SELECT count(*) FROM resources WHERE kind='knowledge' AND spec->>'engine'='lightrag' AND spec->>'endpoint'=$1", kb.Endpoint).Scan(&count); e != nil {
					return e
				}
				if count > 0 {
					return errors.New("each LightRAG knowledge revision requires a distinct workspace endpoint")
				}
			}
			in.Spec = JSON(kb)
		case "agent":
			var a Agent
			if e := json.Unmarshal(in.Spec, &a); e != nil {
				return e
			}
			if e := a.Validate(); e != nil {
				return e
			}
			if e := validateEndpoint(a.Model.BaseURL); e != nil {
				return e
			}
			in.Spec = JSON(a)
		case "skill", "prompt":
			var v Skill
			if e := json.Unmarshal(in.Spec, &v); e != nil {
				return e
			}
			if v.Name == "" || v.Content == "" || len(v.Content) > 40000 {
				return errors.New("name and content (max 40 KB) required")
			}
		case "connector":
			var c Connector
			if e := json.Unmarshal(in.Spec, &c); e != nil {
				return e
			}
			if e := validateEndpoint(c.Endpoint); e != nil {
				return e
			}
			if c.Protocol != "2025-11-25" {
				return errors.New("select supported MCP protocol 2025-11-25")
			}
			for _, t := range c.Tools {
				if !safeName.MatchString(t.Name) {
					return errors.New("invalid MCP tool name")
				}
				if _, e := compileSchema(t.InputSchema); e != nil {
					return e
				}
			}
		}
		v, e := s.Store.PutResource(r.Context(), in.Kind, in.ID, in.Spec)
		if e != nil {
			return e
		}
		jsonResponse(w, 201, v)
		return nil
	}))
	mux.HandleFunc("POST /v1/connectors/discover", wrap(func(w http.ResponseWriter, r *http.Request) error {
		var c Connector
		if e := decode(w, r, &c); e != nil {
			return e
		}
		var e error
		c.AuthToken, e = s.Store.Secret(r.Context(), c.KeyEnv)
		if e != nil {
			return e
		}
		v, e := DiscoverMCP(r.Context(), c)
		if e != nil {
			return e
		}
		jsonResponse(w, 200, v)
		return nil
	}))

}
func (s *Server) runtimeRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/status", wrap(func(w http.ResponseWriter, r *http.Request) error {
		rows, e := s.Store.DB.Query(r.Context(), "SELECT id,role,hostname,pid,heartbeat_at,heartbeat_at>now()-interval '15 seconds' FROM instances ORDER BY role,id")
		if e != nil {
			return e
		}
		defer rows.Close()
		out := []any{}
		for rows.Next() {
			var id, role, host string
			var pid int
			var at time.Time
			var active bool
			if e = rows.Scan(&id, &role, &host, &pid, &at, &active); e != nil {
				return e
			}
			out = append(out, map[string]any{"id": id, "role": role, "hostname": host, "pid": pid, "heartbeat_at": at, "active": active})
		}
		if e = rows.Err(); e != nil {
			return e
		}
		jsonResponse(w, 200, map[string]any{"instances": out})
		return nil
	}))
	mux.HandleFunc("POST /v1/instances", wrap(func(w http.ResponseWriter, r *http.Request) error {
		var in struct {
			ID, Role, Hostname string
			PID                int
		}
		if e := decode(w, r, &in); e != nil {
			return e
		}
		if !safeName.MatchString(in.ID) || !safeName.MatchString(in.Role) || len(in.Hostname) > 255 {
			return errors.New("invalid instance identity")
		}
		if caller := servicehttp.Caller(r.Context()); caller != "" && caller != in.Role {
			return &servicehttp.StatusError{Status: 403, Message: "instance role must match service identity"}
		}
		tag, e := s.Store.DB.Exec(r.Context(), "INSERT INTO instances(id,role,hostname,pid) VALUES($1,$2,$3,$4) ON CONFLICT(id) DO UPDATE SET heartbeat_at=now(),pid=$4 WHERE instances.role=excluded.role AND instances.hostname=excluded.hostname", in.ID, in.Role, in.Hostname, in.PID)
		if e != nil {
			return e
		}
		if tag.RowsAffected() != 1 {
			return errors.New("instance identity already belongs to another service or host")
		}
		jsonResponse(w, 200, map[string]bool{"registered": true})
		return nil
	}))
	mux.HandleFunc("GET /v1/runs", wrap(func(w http.ResponseWriter, r *http.Request) error {
		v, e := s.Store.Runs(r.Context())
		if e != nil {
			return e
		}
		jsonResponse(w, 200, v)
		return nil
	}))
	mux.HandleFunc("POST /v1/runs", wrap(func(w http.ResponseWriter, r *http.Request) error {
		var in struct {
			Agent       Ref      `json:"agent"`
			Task        string   `json:"task"`
			Constraints []string `json:"constraints"`
		}
		if e := decode(w, r, &in); e != nil {
			return e
		}
		key := r.Header.Get("Idempotency-Key")
		if key == "" || len(key) > 200 || strings.TrimSpace(in.Task) == "" || len(in.Task) > 40000 || len(JSON(in.Constraints)) > 16000 {
			return errors.New("idempotency key and bounded task required")
		}
		snap, e := s.Store.Snapshot(r.Context(), in.Agent, 0)
		if e != nil {
			return e
		}
		if _, e = ToolDefinitions(snap); e != nil {
			return e
		}
		id, e := s.Store.Submit(r.Context(), key, in.Task, snap, in.Constraints)
		if e != nil {
			return e
		}
		jsonResponse(w, 201, map[string]string{"id": id})
		return nil
	}))
	mux.HandleFunc("GET /v1/runs/{id}", wrap(func(w http.ResponseWriter, r *http.Request) error {
		v, e := s.Store.Run(r.Context(), r.PathValue("id"))
		if e != nil {
			return e
		}
		jsonResponse(w, 200, v)
		return nil
	}))
	mux.HandleFunc("GET /v1/runs/{id}/events", wrap(func(w http.ResponseWriter, r *http.Request) error {
		after, _ := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
		v, e := s.Store.Events(r.Context(), r.PathValue("id"), after)
		if e != nil {
			return e
		}
		jsonResponse(w, 200, v)
		return nil
	}))
	mux.HandleFunc("GET /v1/runs/{id}/calls", wrap(func(w http.ResponseWriter, r *http.Request) error {
		v, e := s.Store.Calls(r.Context(), r.PathValue("id"))
		if e != nil {
			return e
		}
		jsonResponse(w, 200, v)
		return nil
	}))
	mux.HandleFunc("GET /v1/runs/{id}/usage", wrap(func(w http.ResponseWriter, r *http.Request) error {
		usage, e := s.Store.Usage(r.Context(), r.PathValue("id"))
		if e != nil {
			return e
		}
		jsonResponse(w, 200, usage)
		return nil
	}))
	mux.HandleFunc("POST /v1/runs/{id}/cancel", wrap(func(w http.ResponseWriter, r *http.Request) error {
		if e := s.Store.Cancel(r.Context(), r.PathValue("id")); e != nil {
			return e
		}
		jsonResponse(w, 202, map[string]bool{"cancel_requested": true})
		return nil
	}))
	mux.HandleFunc("POST /v1/runs/{id}/constraints", wrap(func(w http.ResponseWriter, r *http.Request) error {
		var in struct {
			Values []string `json:"values"`
		}
		if e := decode(w, r, &in); e != nil {
			return e
		}
		if e := s.Store.Constraints(r.Context(), r.PathValue("id"), in.Values); e != nil {
			return e
		}
		jsonResponse(w, 200, map[string]bool{"updated": true})
		return nil
	}))
	mux.HandleFunc("POST /v1/runs/{id}/resume", wrap(func(w http.ResponseWriter, r *http.Request) error {
		tag, e := s.Store.DB.Exec(r.Context(), "UPDATE runs SET status='queued',owner='',lease_until=NULL,updated_at=now() WHERE id=$1 AND status='failed' AND NOT cancel_requested", r.PathValue("id"))
		if e != nil {
			return e
		}
		if tag.RowsAffected() != 1 {
			return errors.New("only failed, non-cancelled runs may resume; unknown calls require reconciliation")
		}
		jsonResponse(w, 202, map[string]bool{"queued": true})
		return nil
	}))
	mux.HandleFunc("POST /v1/runs/{id}/reconcile", wrap(func(w http.ResponseWriter, r *http.Request) error {
		var in struct {
			CallID   string          `json:"call_id"`
			Decision string          `json:"decision"`
			Evidence string          `json:"evidence"`
			Result   json.RawMessage `json:"result"`
		}
		if e := decode(w, r, &in); e != nil {
			return e
		}
		if e := s.Store.Resolve(r.Context(), r.PathValue("id"), in.CallID, in.Decision, in.Evidence, in.Result); e != nil {
			return e
		}
		jsonResponse(w, 200, map[string]bool{"reconciled": true})
		return nil
	}))

}
