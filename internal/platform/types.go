package platform

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

var ErrFence = errors.New("lease expired, cancelled, or worker superseded")
var ErrUnknown = errors.New("external operation outcome unknown; reconciliation required")

type Ref struct {
	ID       string `json:"id"`
	Revision int    `json:"revision"`
}
type ModelConfig struct {
	MaxTokens int    `json:"max_tokens,omitempty"`
	BaseURL   string `json:"base_url"`
	Model     string `json:"model"`
	KeyEnv    string `json:"key_env"`
}
type Tool struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"inputSchema"`
}
type Connector struct {
	Name     string `json:"name"`
	Endpoint string `json:"endpoint"`
	KeyEnv   string `json:"key_env"`
	Protocol string `json:"protocol"`
	Tools    []Tool `json:"tools"`
	ReadOnly bool   `json:"read_only"`
	secret   string
}
type Skill struct {
	Name    string `json:"name"`
	Content string `json:"content"`
}
type Agent struct {
	ContextTokens int         `json:"context_tokens"`
	Constraints   []string    `json:"constraints,omitempty"`
	Publication   Publication `json:"publication"`
	Name          string      `json:"name"`
	Prompt        string      `json:"prompt"`
	Prompts       []Ref       `json:"prompts"`
	Skills        []Ref       `json:"skills"`
	Connectors    []Ref       `json:"connectors"`
	Tools         []string    `json:"tools"`
	Model         ModelConfig `json:"model"`
	MaxSteps      int         `json:"max_steps"`
	ContextBytes  int         `json:"context_bytes"`
	MaxChildren   int         `json:"max_children"`
	ChildAgents   []Ref       `json:"child_agents"`
	Knowledge     []Ref       `json:"knowledge"`
}
type Snapshot struct {
	Agent      Agent                    `json:"agent"`
	AgentRef   Ref                      `json:"agent_ref"`
	Skills     []Skill                  `json:"skills"`
	Connectors []Connector              `json:"connectors"`
	Children   map[string]Snapshot      `json:"children,omitempty"`
	Knowledge  map[string]KnowledgeBase `json:"knowledge,omitempty"`
}
type FunctionCall struct {
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
}
type ToolCall struct {
	ID       string       `json:"id"`
	Type     string       `json:"type"`
	Function FunctionCall `json:"function"`
}
type Message struct {
	Role             string     `json:"role"`
	Content          string     `json:"content"`
	ToolCalls        []ToolCall `json:"tool_calls,omitempty"`
	ToolCallID       string     `json:"tool_call_id,omitempty"`
	ReasoningContent string     `json:"reasoning_content,omitempty"`
}
type RunState struct {
	HarnessArtifact string          `json:"harness_artifact,omitempty"`
	Messages        []Message       `json:"messages"`
	Summary         string          `json:"summary,omitempty"`
	Pinned          []string        `json:"pinned"`
	PlanRevision    int64           `json:"plan_revision"`
	ChildrenLoaded  map[string]bool `json:"children_loaded,omitempty"`
	Result          string          `json:"result,omitempty"`
	Error           string          `json:"error,omitempty"`
}
type Run struct {
	Engine          string    `json:"engine"`
	ID              string    `json:"id"`
	ParentID        *string   `json:"parent_id"`
	Task            string    `json:"task"`
	Snapshot        Snapshot  `json:"snapshot"`
	Status          string    `json:"status"`
	Step            int       `json:"step"`
	State           RunState  `json:"state"`
	Owner           string    `json:"owner"`
	Fence           int64     `json:"fence"`
	Constraints     []string  `json:"constraints"`
	RuleRevision    int64     `json:"rule_revision"`
	CancelRequested bool      `json:"cancel_requested"`
	CreatedAt       time.Time `json:"created_at"`
	UpdatedAt       time.Time `json:"updated_at"`
}
type Document struct {
	Scope      string         `json:"scope"`
	ValidUntil *time.Time     `json:"valid_until,omitempty"`
	Truncated  bool           `json:"truncated,omitempty"`
	ID         string         `json:"id"`
	Kind       string         `json:"kind"`
	Title      string         `json:"title"`
	Content    string         `json:"content"`
	Source     string         `json:"source"`
	Metadata   map[string]any `json:"metadata"`
	Supersedes *string        `json:"supersedes,omitempty"`
}
type Resource struct {
	Kind     string          `json:"kind"`
	ID       string          `json:"id"`
	Revision int             `json:"revision"`
	Spec     json.RawMessage `json:"spec"`
}
type Event struct {
	Seq       int64           `json:"seq"`
	Kind      string          `json:"kind"`
	Payload   json.RawMessage `json:"payload"`
	CreatedAt time.Time       `json:"created_at"`
}
type Invocation struct {
	RunID        string          `json:"run_id"`
	Owner        string          `json:"owner"`
	Fence        int64           `json:"fence"`
	RuleRevision int64           `json:"rule_revision"`
	OperationID  string          `json:"operation_id"`
	Name         string          `json:"name"`
	Arguments    json.RawMessage `json:"arguments"`
}

func ID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b[:])
}
func JSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}
func Hash(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }
func Has(values []string, s string) bool {
	for _, v := range values {
		if v == s {
			return true
		}
	}
	return false
}
func (a *Agent) Validate() error {
	if a.ContextTokens == 0 {
		a.ContextTokens = 32000
	}
	if a.ContextTokens < 8192 || a.ContextTokens > 1000000 {
		return errors.New("context_tokens outside 8192..1000000")
	}
	if e := a.Publication.Validate(); e != nil {
		return e
	}
	if strings.TrimSpace(a.Name) == "" || strings.TrimSpace(a.Prompt) == "" {
		return errors.New("name and prompt required")
	}
	if a.MaxSteps == 0 {
		a.MaxSteps = 12
	}
	if a.ContextBytes == 0 {
		a.ContextBytes = 64000
	}
	if a.MaxSteps < 1 || a.MaxSteps > 100 || a.ContextBytes < 4096 || a.ContextBytes > 1000000 || a.MaxChildren < 0 || a.MaxChildren > 8 {
		return errors.New("agent budget outside permitted range")
	}
	if a.Model.Model == "" || a.Model.BaseURL == "" {
		return errors.New("model and base_url required")
	}
	if len(a.Prompt) > a.ContextBytes/2 {
		return errors.New("prompt exceeds pinned context budget")
	}
	for _, r := range append(append(append([]Ref{}, a.Prompts...), a.Skills...), a.Connectors...) {
		if r.ID == "" || r.Revision < 1 {
			return fmt.Errorf("bindings require explicit id and revision")
		}
	}
	return nil
}
