package console

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/euler-gaozl/agent-os/internal/serviceclient"
)

func TestConsoleRoutesNotesToRuntimeAndBytesToStorage(t *testing.T) {
	upstream := func(domain string) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("Authorization") != "Bearer fixture-control-token" {
				t.Error("service identity lost")
			}
			body, _ := io.ReadAll(r.Body)
			w.Header().Set("Content-Type", "text/plain")
			_, _ = io.WriteString(w, domain+" "+r.Method+" "+r.URL.RequestURI()+" "+string(body))
		}))
	}
	runtime, storage := upstream("runtime"), upstream("storage")
	defer runtime.Close()
	defer storage.Close()
	s := &Server{StorageURL: storage.URL, Client: serviceclient.Client{RuntimeURL: runtime.URL, Token: "fixture-control-token"}}
	m := http.NewServeMux()
	s.Routes(m)
	for _, tc := range []struct{ method, path, body, want string }{
		{"GET", "/api/documents?q=retained&kind=memory", "", "runtime GET /v1/documents?q=retained&kind=memory "},
		{"GET", "/api/documents/old-id", "", "runtime GET /v1/documents/old-id "},
		{"POST", "/api/documents", `{"content":"same body"}`, `runtime POST /v1/documents {"content":"same body"}`},
		{"GET", "/api/artifacts/hash", "", "storage GET /artifacts/hash "},
	} {
		w := httptest.NewRecorder()
		m.ServeHTTP(w, httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body)))
		if w.Code != 200 || w.Body.String() != tc.want {
			t.Fatal("wrong data owner", w.Code, w.Body.String())
		}
	}
}
