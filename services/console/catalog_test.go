package console

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync/atomic"
	"testing"

	"github.com/euler-gaozl/agent-os/internal/catalog"
	"github.com/euler-gaozl/agent-os/internal/contracts"
	"github.com/euler-gaozl/agent-os/internal/serviceclient"
)

func TestConsoleMergesOnePageAndCannotAdvancePastUnavailableService(t *testing.T) {
	var calls atomic.Int32
	var offline atomic.Bool
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Path == "/v1/assets/catalog" && offline.Load() {
			w.WriteHeader(503)
			return
		}
		q, e := catalog.Parse(r.URL.Query())
		if e != nil {
			t.Fatal(e)
		}
		kind := "agent"
		if r.URL.Path == "/v1/assets/catalog" {
			kind = "skill"
		}
		items := []contracts.Resource{}
		for _, id := range []string{"A", "Z", "a", "z"} {
			x := contracts.Resource{Kind: kind, ID: id, Revision: 1, Summary: true, Spec: json.RawMessage(`{"name":"fixture"}`)}
			if catalog.Key(x) > q.After {
				items = append(items, x)
			}
		}
		_ = json.NewEncoder(w).Encode(catalog.Finish(items, q.Limit))
	}))
	defer upstream.Close()
	s := &Server{Client: serviceclient.Client{RegistryURL: upstream.URL, CatalogURL: upstream.URL}}
	mux := http.NewServeMux()
	s.Routes(mux)
	read := func(after string) (catalog.Page, map[string]bool) {
		t.Helper()
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, httptest.NewRequest("GET", "/api/catalog?limit=3&after="+url.QueryEscape(after), nil))
		if w.Code != 200 {
			t.Fatal(w.Code)
		}
		var p struct {
			catalog.Page
			Services map[string]bool `json:"services"`
		}
		if e := json.Unmarshal(w.Body.Bytes(), &p); e != nil {
			t.Fatal(e)
		}
		return p.Page, p.Services
	}
	seen := map[string]bool{}
	after := ""
	for i := 0; i < 3; i++ {
		before := calls.Load()
		p, _ := read(after)
		if calls.Load()-before != 2 {
			t.Fatal("BFF fetched multiple upstream pages")
		}
		for _, r := range p.Items {
			key := catalog.Key(r)
			if seen[key] {
				t.Fatal("repeated index row")
			}
			seen[key] = true
		}
		after = p.Next
	}
	if len(seen) != 8 || after != "" {
		t.Fatal("incomplete merged index")
	}
	offline.Store(true)
	p, status := read("")
	if status["toolhub"] || !status["registry"] || len(p.Items) != 3 || p.Next != "" {
		t.Fatal("partial failure skipped unavailable index entries")
	}
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", "/api/catalog?limit=1000000", nil))
	if w.Code != 400 {
		t.Fatal("unbounded query accepted")
	}
}
