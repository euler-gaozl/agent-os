package servicehttp

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

func TestClosedDatabaseConnectionIsUnavailable(t *testing.T) {
	for _, cause := range []error{io.ErrUnexpectedEOF, pgconn.ErrConnClosed} {
		w := httptest.NewRecorder()
		Wrap(func(http.ResponseWriter, *http.Request) error {
			return fmt.Errorf("private database context: %w", cause)
		})(w, httptest.NewRequest("POST", "/fixture", nil))
		if w.Code != 503 || strings.Contains(w.Body.String(), "private") || w.Header().Get("Retry-After") != "1" {
			t.Fatal("closed connection misclassified or leaked details", w.Code, w.Body.String())
		}
	}
}

func TestDatabaseCapacityFailuresAreUnavailableNotBadInput(t *testing.T) {
	for _, code := range []string{"53100", "53200", "53300", "08006", "57P01", "57P02", "57P03", "57014"} {
		w := httptest.NewRecorder()
		h := Wrap(func(http.ResponseWriter, *http.Request) error {
			return fmt.Errorf("retaining data: %w", &pgconn.PgError{Code: code, Message: "private database path and query must not be returned"})
		})
		h(w, httptest.NewRequest("POST", "/fixture", nil))
		want := 503
		if code == "57014" {
			want = 504
		}
		if w.Code != want || strings.Contains(w.Body.String(), "private") || (want == 503 && w.Header().Get("Retry-After") != "1") {
			t.Fatal("operational failure classified as client input or leaked internal detail", code, w.Code, w.Body.String())
		}
	}
	w := httptest.NewRecorder()
	Wrap(func(http.ResponseWriter, *http.Request) error {
		return &pgconn.PgError{Code: "23505", Message: "resource already exists"}
	})(w, httptest.NewRequest("POST", "/fixture", nil))
	if w.Code != 400 {
		t.Fatal("validation conflict was declared retryable", w.Code)
	}
}

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
