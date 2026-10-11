package platform

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
)

type BusinessAction struct {
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Agent       Ref      `json:"agent"`
	Instruction string   `json:"instruction"`
	Constraints []string `json:"constraints"`
}

func (s *Server) futuresRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/agents", wrap(func(w http.ResponseWriter, r *http.Request) error {
		resources, e := s.Store.Resources(r.Context())
		if e != nil {
			return e
		}
		out := []any{}
		for _, resource := range resources {
			if resource.Kind != "agent" {
				continue
			}
			var a Agent
			if e = json.Unmarshal(resource.Spec, &a); e != nil {
				return e
			}
			if !a.Publication.Enabled || a.Publication.App != "futures" {
				continue
			}
			out = append(out, map[string]any{"id": resource.ID, "revision": resource.Revision, "name": a.Publication.Name, "description": a.Publication.Description})
		}
		jsonResponse(w, 200, out)
		return nil
	}))
	mux.HandleFunc("POST /api/tasks", wrap(func(w http.ResponseWriter, r *http.Request) error {
		var in struct {
			Agent     Ref    `json:"agent"`
			Commodity string `json:"commodity"`
			Period    string `json:"period"`
			Question  string `json:"question"`
		}
		if e := decode(w, r, &in); e != nil {
			return e
		}
		if strings.TrimSpace(in.Commodity) == "" || len(in.Commodity) > 100 || len(in.Period) > 300 || len(in.Question) > 20000 {
			return errors.New("commodity and bounded research question required")
		}
		var agent Agent
		if e := s.Store.Resource(r.Context(), "agent", in.Agent, &agent); e != nil {
			return e
		}
		var latest int
		if e := s.Store.DB.QueryRow(r.Context(), "SELECT max(revision) FROM resources WHERE kind='agent' AND id=$1", in.Agent.ID).Scan(&latest); e != nil {
			return e
		}
		if !agent.Publication.Enabled || agent.Publication.App != "futures" || latest != in.Agent.Revision {
			return errors.New("agent is unpublished or version changed; refresh the workspace")
		}
		body := JSON(map[string]any{"agent": in.Agent, "task": fmt.Sprintf("品种：%s\n资料时间范围：%s\n用户问题：%s", in.Commodity, in.Period, in.Question)})
		request, e := http.NewRequestWithContext(r.Context(), "POST", s.RuntimeURL+"/v1/runs", bytes.NewReader(body))
		if e != nil {
			return e
		}
		request.Header.Set("Authorization", "Bearer "+s.Token)
		request.Header.Set("Content-Type", "application/json")
		request.Header.Set("Idempotency-Key", "futures:"+r.Header.Get("Idempotency-Key"))
		if r.Header.Get("Idempotency-Key") == "" {
			return errors.New("idempotency key required")
		}
		resp, e := externalHTTP.Do(request)
		if e != nil {
			return e
		}
		defer resp.Body.Close()
		raw, e := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		if e != nil {
			return e
		}
		if resp.StatusCode != 201 {
			return fmt.Errorf("runtime refused task: %s", truncateUTF8(string(raw), 300))
		}
		var accepted struct {
			ID string `json:"id"`
		}
		if e = json.Unmarshal(raw, &accepted); e != nil {
			return e
		}
		if _, e = s.Store.DB.Exec(r.Context(), "INSERT INTO business_runs(run_id,action_id,action_revision,commodity,agent_id,agent_revision) VALUES($1,'',0,$4,$2,$3) ON CONFLICT(run_id) DO NOTHING", accepted.ID, in.Agent.ID, in.Agent.Revision, in.Commodity); e != nil {
			return e
		}
		jsonResponse(w, 201, map[string]string{"id": accepted.ID})
		return nil
	}))
	mux.HandleFunc("GET /api/tasks", wrap(func(w http.ResponseWriter, r *http.Request) error {
		rows, e := s.Store.DB.Query(r.Context(), "SELECT b.run_id,b.commodity,r.status,r.created_at FROM business_runs b JOIN runs r ON r.id=b.run_id ORDER BY b.created_at DESC LIMIT 100")
		if e != nil {
			return e
		}
		defer rows.Close()
		out := []any{}
		for rows.Next() {
			var id, commodity, status string
			var at any
			if e = rows.Scan(&id, &commodity, &status, &at); e != nil {
				return e
			}
			out = append(out, map[string]any{"id": id, "commodity": commodity, "status": status, "created_at": at})
		}
		if e = rows.Err(); e != nil {
			return e
		}
		jsonResponse(w, 200, out)
		return nil
	}))
	mux.HandleFunc("GET /api/tasks/{id}", wrap(func(w http.ResponseWriter, r *http.Request) error {
		var commodity string
		if e := s.Store.DB.QueryRow(r.Context(), "SELECT commodity FROM business_runs WHERE run_id=$1", r.PathValue("id")).Scan(&commodity); e != nil {
			return e
		}
		raw, e := providerJSON(r.Context(), "GET", s.RuntimeURL+"/v1/runs/"+r.PathValue("id"), s.Token, "", nil)
		if e != nil {
			return e
		}
		var run Run
		if e = json.Unmarshal(raw, &run); e != nil {
			return e
		}
		// Project a business result, excluding prompts, tool schemas and raw call payloads.
		jsonResponse(w, 200, map[string]any{"id": run.ID, "commodity": commodity, "status": run.Status, "step": run.Step, "result": run.State.Result, "error": run.State.Error, "created_at": run.CreatedAt})
		return nil
	}))
	mux.HandleFunc("POST /api/tasks/{id}/cancel", wrap(func(w http.ResponseWriter, r *http.Request) error {
		var exists bool
		if e := s.Store.DB.QueryRow(r.Context(), "SELECT EXISTS(SELECT 1 FROM business_runs WHERE run_id=$1)", r.PathValue("id")).Scan(&exists); e != nil {
			return e
		}
		if !exists {
			return errors.New("task not found")
		}
		raw, e := internalRequest(r.Context(), s.RuntimeURL+"/v1/runs/"+r.PathValue("id")+"/cancel", s.Token, map[string]any{})
		if e != nil {
			return e
		}
		w.Header().Set("Content-Type", "application/json")
		_, e = w.Write(raw)
		return e
	}))
	mux.HandleFunc("GET /api/readiness", wrap(func(w http.ResponseWriter, r *http.Request) error {
		_, keyErr := s.Store.Secret(r.Context(), "DEEPSEEK_API_KEY")
		var count int
		if e := s.Store.DB.QueryRow(r.Context(), "SELECT count(*) FROM knowledge_files WHERE status='ready'").Scan(&count); e != nil {
			return e
		}
		jsonResponse(w, 200, map[string]any{"model_configured": keyErr == nil, "indexed_documents": count})
		return nil
	}))
	if s.WebDir != "" {
		mux.Handle("/", http.FileServer(http.Dir(s.WebDir)))
	}
}
