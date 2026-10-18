package platform

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

// Exercise the real harness bridge: the operator's cap must survive DSH's own
// default, and a thinking tool turn must preserve the provider-required field.
func TestDSHProviderOptionsAndReasoningRoundTrip(t *testing.T) {
	setupDSH(t)
	s, _ := testStore(t)
	var requests atomic.Int32
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			MaxTokens int `json:"max_tokens"`
			Thinking  struct {
				Type string `json:"type"`
			} `json:"thinking"`
			Effort   string    `json:"reasoning_effort"`
			Messages []Message `json:"messages"`
		}
		if e := json.NewDecoder(r.Body).Decode(&body); e != nil {
			t.Error(e)
		}
		if body.MaxTokens != 512 || body.Thinking.Type != "enabled" || body.Effort != "low" {
			t.Errorf("provider options not respected: %+v", body)
		}
		if requests.Add(1) == 1 {
			completion(w, Message{Role: "assistant", ReasoningContent: "fixture reasoning", ToolCalls: []ToolCall{{ID: "lookup", Type: "function", Function: FunctionCall{Name: "knowledge_search", Arguments: `{"query":"fixture"}`}}}})
			return
		}
		found := false
		for _, m := range body.Messages {
			if m.ReasoningContent == "fixture reasoning" {
				found = true
			}
		}
		if !found {
			t.Error("provider reasoning_content missing after tool call")
		}
		completion(w, Message{Role: "assistant", Content: "tool round trip complete"})
	}))
	defer model.Close()
	hub := httptest.NewServer((&Server{Store: s, Role: "toolhub", Token: testToken}).Handler())
	defer hub.Close()
	snap := basicSnapshot(model.URL)
	snap.Agent.Model.MaxTokens = 512
	snap.Agent.Model.Thinking = "enabled"
	snap.Agent.Model.ReasoningEffort = "low"
	id := submit(t, s, snap)
	r := claim(t, s, "provider-check")
	w := Worker{Store: s, Lease: 10 * time.Second, ToolHubURL: hub.URL, Token: testToken}
	w.execute(context.Background(), r)
	done, e := s.Run(context.Background(), id)
	if e != nil || done.Status != "completed" || requests.Load() != 2 {
		t.Fatalf("provider run failed: %s %s %v", done.Status, done.State.Error, e)
	}
}

func TestModelRequestDoesNotChangeLegacyDefaults(t *testing.T) {
	var body map[string]any
	_ = json.Unmarshal(ModelRequest(ModelConfig{Model: "fixture"}, []Message{{Role: "user", Content: "hello"}}, nil), &body)
	for _, k := range []string{"thinking", "reasoning_effort", "max_tokens"} {
		if _, ok := body[k]; ok {
			t.Fatalf("legacy request unexpectedly gained %s", k)
		}
	}
}
