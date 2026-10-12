package console

import (
	"context"
	"github.com/euler-gaozl/agent-os/internal/catalog"
	"github.com/euler-gaozl/agent-os/internal/contracts"
	"github.com/euler-gaozl/agent-os/internal/serviceclient"
	"github.com/euler-gaozl/agent-os/internal/servicehttp"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

type Server struct {
	HTTP                             servicehttp.Config
	Client                           serviceclient.Client
	KnowledgeURL, StorageURL, WebDir string
	SourcesURL                       string
}

func (s *Server) Handler() http.Handler { return servicehttp.New(s.HTTP, nil, s.Routes) }
func (s *Server) Routes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/catalog", servicehttp.Wrap(s.catalog))
	mux.HandleFunc("GET /api/resources/", func(w http.ResponseWriter, r *http.Request) {
		s.proxy(w, r, s.Client.RegistryURL+strings.Replace(r.URL.Path, "/api/", "/v1/", 1))
	})
	for _, prefix := range []string{"/api/resources", "/api/credentials"} {
		mux.HandleFunc(prefix, func(w http.ResponseWriter, r *http.Request) {
			if r.Method == "GET" && r.URL.Path == "/api/resources" {
				s.resources(w, r)
				return
			}
			s.proxy(w, r, s.Client.RegistryURL+strings.Replace(r.URL.Path, "/api/", "/v1/", 1))
		})
	}
	mux.HandleFunc("/api/connectors/discover", func(w http.ResponseWriter, r *http.Request) { s.proxy(w, r, s.Client.CatalogURL+"/v1/discover") })
	mux.HandleFunc("/api/toolhub/", func(w http.ResponseWriter, r *http.Request) {
		s.proxy(w, r, s.Client.CatalogURL+strings.Replace(r.URL.Path, "/api/toolhub/", "/v1/", 1))
	})
	mux.HandleFunc("/api/sources/", func(w http.ResponseWriter, r *http.Request) {
		s.proxy(w, r, s.SourcesURL+strings.TrimPrefix(r.URL.Path, "/api/sources"))
	})
	for _, prefix := range []string{"/api/runs", "/api/runs/"} {
		mux.HandleFunc(prefix, func(w http.ResponseWriter, r *http.Request) {
			s.proxy(w, r, s.Client.RuntimeURL+strings.Replace(r.URL.Path, "/api/", "/v1/", 1))
		})
	}
	mux.HandleFunc("/api/knowledge/", func(w http.ResponseWriter, r *http.Request) {
		s.proxy(w, r, s.KnowledgeURL+strings.Replace(r.URL.Path, "/api/knowledge/", "/v1/", 1))
	})
	for _, prefix := range []string{"/api/documents", "/api/documents/"} {
		mux.HandleFunc(prefix, func(w http.ResponseWriter, r *http.Request) {
			s.proxy(w, r, s.Client.RuntimeURL+strings.Replace(r.URL.Path, "/api/", "/v1/", 1))
		})
	}
	for _, prefix := range []string{"/api/artifacts/"} {
		mux.HandleFunc(prefix, func(w http.ResponseWriter, r *http.Request) {
			s.proxy(w, r, s.StorageURL+strings.TrimPrefix(r.URL.Path, "/api"))
		})
	}
	mux.HandleFunc("GET /api/status", servicehttp.Wrap(func(w http.ResponseWriter, r *http.Request) error {
		var result map[string]any
		if e := s.Client.Request(r.Context(), "GET", s.Client.RuntimeURL+"/v1/status", nil, &result); e != nil {
			return e
		}
		var credentials map[string]any
		e := s.Client.Request(r.Context(), "GET", s.Client.RegistryURL+"/v1/status", nil, &credentials)
		result["deepseek_configured"] = e == nil && credentials["deepseek_configured"] == true
		result["local_mode"] = s.HTTP.DevLocal
		result["version"] = "0.5.0"
		servicehttp.JSONResponse(w, 200, result)
		return nil
	}))
	if s.WebDir != "" {
		mux.Handle("/", http.FileServer(http.Dir(s.WebDir)))
	}
}

func (s *Server) catalog(w http.ResponseWriter, r *http.Request) error {
	q, err := catalog.Parse(r.URL.Query())
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
	defer cancel()
	type result struct {
		role string
		page catalog.Page
		err  error
	}
	ch := make(chan result, 2)
	for role, base := range map[string]string{"registry": s.Client.RegistryURL + "/v1/catalog", "toolhub": s.Client.CatalogURL + "/v1/assets/catalog"} {
		go func(role, base string) {
			var p catalog.Page
			e := s.Client.Request(ctx, "GET", base+"?"+r.URL.RawQuery, nil, &p)
			ch <- result{role, p, e}
		}(role, base)
	}
	items := []contracts.Resource{}
	status := map[string]bool{}
	more := false
	for i := 0; i < 2; i++ {
		v := <-ch
		status[v.role] = v.err == nil
		if v.err == nil {
			items = append(items, v.page.Items...)
			more = more || v.page.Next != ""
		}
	}
	sort.Slice(items, func(i, j int) bool { return catalog.Key(items[i]) < catalog.Key(items[j]) })
	p := catalog.Finish(items, q.Limit)
	if more && p.Next == "" && len(p.Items) > 0 {
		p.Next = catalog.Key(p.Items[len(p.Items)-1])
	}
	// Do not skip an unavailable service's entries by advancing a partial page.
	needRegistry := q.Kind == "" || q.Kind == "agent" || q.Kind == "prompt" || q.Kind == "knowledge"
	needToolhub := q.Kind == "" || q.Kind == "skill" || q.Kind == "connector"
	if (needRegistry && !status["registry"]) || (needToolhub && !status["toolhub"]) {
		p.Next = ""
	}
	servicehttp.JSONResponse(w, 200, map[string]any{"items": p.Items, "next_cursor": p.Next, "services": status})
	return nil
}
func (s *Server) proxy(w http.ResponseWriter, r *http.Request, target string) {
	Proxy(w, r, target, s.Client.Token)
}
func Proxy(w http.ResponseWriter, r *http.Request, target, token string) {
	if r.URL.RawQuery != "" {
		target += "?" + r.URL.RawQuery
	}
	req, e := http.NewRequestWithContext(r.Context(), r.Method, target, http.MaxBytesReader(w, r.Body, 2<<20))
	if e != nil {
		servicehttp.JSONResponse(w, 400, map[string]string{"error": "invalid request"})
		return
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Idempotency-Key", r.Header.Get("Idempotency-Key"))
	resp, e := servicehttp.Client.Do(req)
	if e != nil {
		servicehttp.JSONResponse(w, 503, map[string]string{"error": "upstream service unavailable"})
		return
	}
	defer resp.Body.Close()
	for _, h := range []string{"Content-Type", "Content-Disposition", "X-Artifact-Media-Type", "Retry-After"} {
		if v := resp.Header.Get(h); v != "" {
			w.Header().Set(h, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, io.LimitReader(resp.Body, 4<<20))
}

// Catalog availability is independent from Registry. The console returns partial
// resources with explicit service status; it never presents outage as empty data.
func (s *Server) resources(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
	defer cancel()
	type result struct {
		role  string
		items []contracts.Resource
		err   error
	}
	results := make(chan result, 2)
	go func() {
		var items []contracts.Resource
		e := s.Client.Request(ctx, "GET", s.Client.RegistryURL+"/v1/resources?after="+url.QueryEscape(r.URL.Query().Get("after")), nil, &items)
		results <- result{"registry", items, e}
	}()
	go func() {
		items := []contracts.Resource{}
		after := r.URL.Query().Get("after")
		e := s.Client.Request(ctx, "GET", s.Client.CatalogURL+"/v1/assets?limit=100&after="+url.QueryEscape(after), nil, &items)
		results <- result{"toolhub", items, e}
	}()
	out := []contracts.Resource{}
	status := map[string]bool{}
	for i := 0; i < 2; i++ {
		v := <-results
		status[v.role] = v.err == nil
		if v.err == nil {
			out = append(out, v.items...)
		}
	}
	sort.Slice(out, func(i, j int) bool { return catalog.Key(out[i]) < catalog.Key(out[j]) })
	size, end := 0, 0
	for _, item := range out {
		n := len(contracts.JSON(item))
		if end > 0 && size+n > 2<<20 {
			break
		}
		size += n
		end++
	}
	out = out[:end]
	next := ""
	if len(out) > 0 && status["registry"] && status["toolhub"] {
		next = catalog.Key(out[len(out)-1])
	}
	servicehttp.JSONResponse(w, 200, map[string]any{"items": out, "services": status, "next_cursor": next})
}
