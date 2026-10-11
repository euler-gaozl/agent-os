package mcp

import (
	"context"
	"github.com/euler-gaozl/agent-os/internal/contracts"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestRPCRejectsUnrelatedOrMalformedResponse(t *testing.T) {
	for _, tc := range []struct {
		name, media, body string
		ok                bool
	}{
		{"json", "application/json", `{"jsonrpc":"2.0","id":1,"result":{"ok":true}}`, true},
		{"wrong id", "application/json", `{"jsonrpc":"2.0","id":2,"result":{"ok":true}}`, false},
		{"missing version", "application/json", `{"id":1,"result":{}}`, false},
		{"unsolicited stream", "text/event-stream", "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}\n\n", false},
		{"notification then reply", "text/event-stream", "data: {\"jsonrpc\":\"2.0\",\"method\":\"progress\"}\n\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", tc.media)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer s.Close()
			m := MCPClient{Connector: contracts.Connector{Endpoint: s.URL}}
			_, e := m.RPC(context.Background(), "tools/list", map[string]any{}, false)
			if (e == nil) != tc.ok {
				t.Fatalf("accepted=%v want=%v: %v", e == nil, tc.ok, e)
			}
		})
	}
}
