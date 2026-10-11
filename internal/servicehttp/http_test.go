package servicehttp

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestServiceIdentityCannotCrossAdministrativeBoundary(t *testing.T) {
	tokens := map[string]string{"control": strings.Repeat("c", 40), "futures": strings.Repeat("f", 40), "worker": strings.Repeat("w", 40)}
	peers := map[string]string{}
	for k, v := range tokens {
		peers[k] = TokenHash(v)
	}
	h := New(Config{Role: "registry", Peers: peers}, nil, func(m *http.ServeMux) {
		m.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })
	})
	for _, tc := range []struct {
		role, method, path string
		want               int
	}{{"futures", "POST", "/v1/credentials/resolve", 403}, {"futures", "POST", "/v1/resources", 403}, {"control", "POST", "/v1/credentials/resolve", 403}, {"control", "POST", "/v1/resources", 204}, {"worker", "POST", "/v1/credentials/resolve", 204}, {"worker", "POST", "/v1/resources", 403}, {"futures", "GET", "/v1/published/futures", 204}, {"", "GET", "/v1/resources", 401}} {
		r := httptest.NewRequest(tc.method, tc.path, nil)
		r.Header.Set("Authorization", "Bearer "+tokens[tc.role])
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != tc.want {
			t.Fatalf("%+v got %d", tc, w.Code)
		}
	}
}
func TestSaturationLeavesHealthAvailableAndBoundsWork(t *testing.T) {
	token := strings.Repeat("t", 40)
	entered := make(chan struct{})
	release := make(chan struct{})
	done := make(chan struct{})
	h := New(Config{Role: "test", Token: token, MaxConcurrent: 1}, func(context.Context) error { return errors.New("database down") }, func(m *http.ServeMux) {
		m.HandleFunc("/work", func(w http.ResponseWriter, r *http.Request) { close(entered); <-release; w.WriteHeader(204) })
	})
	request := func(path string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", path, nil)
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	go func() { defer close(done); request("/work") }()
	<-entered
	if w := request("/work"); w.Code != 429 || w.Header().Get("Retry-After") == "" {
		t.Fatal(w.Code)
	}
	if w := request("/healthz"); w.Code != 200 {
		t.Fatal(w.Code)
	}
	if w := request("/readyz"); w.Code != 503 {
		t.Fatal(w.Code)
	}
	close(release)
	<-done
}
func TestDeadlineAndMalformedJSON(t *testing.T) {
	token := strings.Repeat("t", 40)
	h := New(Config{Role: "test", Token: token, RequestTimeout: 10 * time.Millisecond}, nil, func(m *http.ServeMux) {
		m.HandleFunc("/slow", Wrap(func(w http.ResponseWriter, r *http.Request) error { <-r.Context().Done(); return r.Context().Err() }))
		m.HandleFunc("/json", Wrap(func(w http.ResponseWriter, r *http.Request) error { var v struct{ ID string }; return Decode(w, r, &v) }))
	})
	for _, tc := range []struct {
		path, body string
		want       int
	}{{"/slow", "", 504}, {"/json", `{"id":"a"}{"id":"b"}`, 400}, {"/json", `{"password":"unexpected"}`, 400}} {
		r := httptest.NewRequest("POST", tc.path, strings.NewReader(tc.body))
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != tc.want {
			t.Fatal(w.Code)
		}
	}
}
