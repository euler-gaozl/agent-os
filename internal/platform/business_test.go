package platform

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestBusinessUsesRuntimeAndHidesPlatformConfiguration(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	agent := basicSnapshot("http://127.0.0.1").Agent
	agent.Publication = Publication{true, "futures", "Fixture research", "Protocol test"}
	a, e := s.PutResource(ctx, "agent", "fixture", JSON(agent))
	if e != nil {
		t.Fatal(e)
	}
	runtime := httptest.NewServer((&Server{Store: s, Role: "runtime", Token: testToken}).Handler())
	defer runtime.Close()
	business := httptest.NewServer((&Server{Store: s, Role: "futures", Token: testToken, AdminToken: testToken, RuntimeURL: runtime.URL}).Handler())
	defer business.Close()
	send := func(method, path string, body any) []byte {
		t.Helper()
		var reader io.Reader
		if body != nil {
			reader = bytes.NewReader(JSON(body))
		}
		req, _ := http.NewRequest(method, business.URL+path, reader)
		req.Header.Set("Authorization", "Bearer "+testToken)
		req.Header.Set("Idempotency-Key", "business-fixture")
		response, e := http.DefaultClient.Do(req)
		if e != nil {
			t.Fatal(e)
		}
		defer response.Body.Close()
		b, _ := io.ReadAll(response.Body)
		if response.StatusCode >= 300 {
			t.Fatalf("HTTP %d: %s", response.StatusCode, b)
		}
		return b
	}
	actions := send("GET", "/api/agents", nil)
	if strings.Contains(string(actions), "instruction") || strings.Contains(string(actions), "agent") {
		t.Fatal("private action configuration exposed")
	}
	input := map[string]any{"agent": Ref{a.ID, a.Revision}, "commodity": "test-fixture", "question": "fixture only", "period": "test"}
	raw := send("POST", "/api/tasks", input)
	var accepted struct {
		ID string `json:"id"`
	}
	if e = json.Unmarshal(raw, &accepted); e != nil {
		t.Fatal(e)
	}
	duplicate := send("POST", "/api/tasks", input)
	var second struct {
		ID string `json:"id"`
	}
	json.Unmarshal(duplicate, &second)
	if second.ID != accepted.ID {
		t.Fatal("duplicate business dispatch")
	}
	detail := send("GET", "/api/tasks/"+accepted.ID, nil)
	for _, name := range []string{"snapshot", "key_env", "tools", "prompt", "connectors"} {
		if strings.Contains(string(detail), `"`+name+`"`) {
			t.Fatal("business API leaked platform field", name)
		}
	}
	if e = s.DB.QueryRow(ctx, "SELECT count(*) FROM business_runs").Scan(new(int)); e != nil {
		t.Fatal(e)
	}
	req, _ := http.NewRequest("GET", business.URL+"/api/resources", nil)
	req.Header.Set("Authorization", "Bearer "+testToken)
	resp, e := http.DefaultClient.Do(req)
	if e != nil {
		t.Fatal(e)
	}
	resp.Body.Close()
	if resp.StatusCode != 404 {
		t.Fatal("business API exposes platform catalog")
	}
}

func TestControlProxyPreservesSubmissionIdempotency(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	a, e := s.PutResource(ctx, "agent", "fixture", JSON(basicSnapshot("http://127.0.0.1").Agent))
	if e != nil {
		t.Fatal(e)
	}
	runtime := httptest.NewServer((&Server{Store: s, Role: "runtime", Token: testToken}).Handler())
	defer runtime.Close()
	control := httptest.NewServer((&Server{Store: s, Role: "control", Token: testToken, AdminToken: testToken, RuntimeURL: runtime.URL}).Handler())
	defer control.Close()
	var first string
	for i := 0; i < 2; i++ {
		req, _ := http.NewRequest("POST", control.URL+"/api/runs", bytes.NewReader(JSON(map[string]any{"agent": Ref{a.ID, a.Revision}, "task": "proxy fixture", "constraints": []string{}})))
		req.Header.Set("Authorization", "Bearer "+testToken)
		req.Header.Set("Idempotency-Key", "same-proxy-key")
		resp, e := http.DefaultClient.Do(req)
		if e != nil {
			t.Fatal(e)
		}
		var result map[string]string
		json.NewDecoder(resp.Body).Decode(&result)
		resp.Body.Close()
		if resp.StatusCode != 201 {
			t.Fatal(result)
		}
		if i == 0 {
			first = result["id"]
		} else if first != result["id"] {
			t.Fatal("proxy lost idempotency header")
		}
	}
}
