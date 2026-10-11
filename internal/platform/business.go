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
	mux.HandleFunc("GET /api/actions", wrap(func(w http.ResponseWriter, r *http.Request) error {
		resources, e := s.Store.Resources(r.Context())
		if e != nil {
			return e
		}
		out := []any{}
		for _, resource := range resources {
			if resource.Kind != "action" {
				continue
			}
			var a BusinessAction
			if e = json.Unmarshal(resource.Spec, &a); e != nil {
				return e
			}
			out = append(out, map[string]any{"id": resource.ID, "revision": resource.Revision, "name": a.Name, "description": a.Description})
		}
		jsonResponse(w, 200, out)
		return nil
	}))
	mux.HandleFunc("POST /api/tasks", wrap(func(w http.ResponseWriter, r *http.Request) error {
		var in struct {
			Action    Ref    `json:"action"`
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
		var action BusinessAction
		if e := s.Store.Resource(r.Context(), "action", in.Action, &action); e != nil {
			return e
		}
		// Business requests choose a published capability, never credentials or low-level tools.
		body := JSON(map[string]any{"agent": action.Agent, "task": fmt.Sprintf("%s\n品种：%s\n资料时间范围：%s\n用户问题：%s", action.Instruction, in.Commodity, in.Period, in.Question), "constraints": action.Constraints})
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
		if _, e = s.Store.DB.Exec(r.Context(), "INSERT INTO business_runs(run_id,action_id,action_revision,commodity) VALUES($1,$2,$3,$4) ON CONFLICT(run_id) DO NOTHING", accepted.ID, in.Action.ID, in.Action.Revision, in.Commodity); e != nil {
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
