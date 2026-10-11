package platform

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

func tool(name, description, schema string) Tool {
	return Tool{name, description, json.RawMessage(schema)}
}

var Builtins = []Tool{
	tool("knowledge_search", "Search saved evidence, facts, knowledge and memory. Returns provenance. No live market data.", `{"type":"object","properties":{"query":{"type":"string","maxLength":300},"kind":{"type":"string","enum":["","knowledge","memory","evidence","fact"]}},"required":["query"],"additionalProperties":false}`),
	tool("note_save", "Save a sourced observation as an immutable document. Distinguish fact, evidence and memory.", `{"type":"object","properties":{"kind":{"type":"string","enum":["knowledge","memory","evidence","fact"]},"title":{"type":"string","minLength":1,"maxLength":300},"content":{"type":"string","minLength":1,"maxLength":20000},"source":{"type":"string","minLength":1,"maxLength":2000},"metadata":{"type":"object"}},"required":["kind","title","content","source"],"additionalProperties":false}`),
	tool("artifact_read", "Read a retained UTF-8 artifact by hash in pages; offset and limit count Unicode characters.", `{"type":"object","properties":{"hash":{"type":"string","pattern":"^[a-f0-9]{64}$"},"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":1200}},"required":["hash"],"additionalProperties":false}`),
	tool("spawn_agent", "Start a permitted child agent. Parent waits durably for children; results become context.", `{"type":"object","properties":{"agent_id":{"type":"string"},"task":{"type":"string","minLength":1,"maxLength":20000}},"required":["agent_id","task"],"additionalProperties":false}`),
	tool("sandbox_exec", "Execute JavaScript in a restricted disposable container without network or host mounts.", `{"type":"object","properties":{"code":{"type":"string","minLength":1,"maxLength":30000}},"required":["code"],"additionalProperties":false}`),
	tool("document_read", "Read a sourced document by id in pages, including historical revisions. Respect its scope and validity dates.", `{"type":"object","properties":{"id":{"type":"string"},"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":1200}},"required":["id"],"additionalProperties":false}`),
}
var safeName = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,128}$`)

// Resolve exact expanded names; connector names can share prefixes.
func connectorForTool(snap Snapshot, name string) (Connector, string, bool) {
	for _, c := range snap.Connectors {
		for _, t := range c.Tools {
			if name == "mcp_"+c.Name+"_"+t.Name {
				return c, t.Name, true
			}
		}
	}
	return Connector{}, "", false
}

func ToolDefinitions(snap Snapshot) ([]Tool, error) {
	out := []Tool{}
	seen := map[string]bool{}
	for _, name := range snap.Agent.Tools {
		found := false
		for _, t := range Builtins {
			if t.Name == name {
				out = append(out, t)
				found = true
				break
			}
		}
		if !found {
			return nil, fmt.Errorf("unknown builtin: %s", name)
		}
	}
	for _, c := range snap.Connectors {
		for _, t := range c.Tools {
			t.Name = "mcp_" + c.Name + "_" + t.Name
			out = append(out, t)
		}
	}
	if len(snap.Knowledge) > 0 {
		ids := []string{}
		for _, ref := range snap.Agent.Knowledge {
			ids = append(ids, ref.ID)
		}
		out = append(out, Tool{Name: "kb_search", Description: "Retrieve evidence from a bound knowledge base; cites original documents. Graph relationships are extracted claims, not verified facts.", InputSchema: JSON(map[string]any{"type": "object", "properties": map[string]any{"kb_id": map[string]any{"type": "string", "enum": ids}, "query": map[string]any{"type": "string", "minLength": 1, "maxLength": 1000}}, "required": []string{"kb_id", "query"}, "additionalProperties": false})})
	}
	for _, t := range out {
		if !safeName.MatchString(t.Name) || seen[t.Name] {
			return nil, errors.New("invalid or duplicate tool name")
		}
		seen[t.Name] = true
		if _, e := compileSchema(t.InputSchema); e != nil {
			return nil, e
		}
	}
	return out, nil
}
func compileSchema(b []byte) (*jsonschema.Schema, error) {
	var v any
	if e := json.Unmarshal(b, &v); e != nil {
		return nil, e
	}
	var check func(any) error
	check = func(v any) error {
		switch x := v.(type) {
		case map[string]any:
			for k, v := range x {
				if k == "$ref" || k == "$dynamicRef" {
					if ref, ok := v.(string); !ok || !strings.HasPrefix(ref, "#") {
						return errors.New("external schema references are not allowed")
					}
				}
				if e := check(v); e != nil {
					return e
				}
			}
		case []any:
			for _, v := range x {
				if e := check(v); e != nil {
					return e
				}
			}
		}
		return nil
	}
	if e := check(v); e != nil {
		return nil, e
	}
	c := jsonschema.NewCompiler()
	if e := c.AddResource("urn:agentos:tool", v); e != nil {
		return nil, e
	}
	return c.Compile("urn:agentos:tool")
}
func validateArgs(t Tool, args []byte) error {
	var v any
	if e := json.Unmarshal(args, &v); e != nil {
		return e
	}
	schema, e := compileSchema(t.InputSchema)
	if e != nil {
		return e
	}
	return schema.Validate(v)
}
func authorize(r Run, inv Invocation) error {
	ts, e := ToolDefinitions(r.Snapshot)
	if e != nil {
		return e
	}
	for _, t := range ts {
		if t.Name == inv.Name {
			return validateArgs(t, inv.Arguments)
		}
	}
	return errors.New("tool is not bound to this agent revision")
}

// Local effects and operation receipts commit together while the run fence is locked.
func (s *Store) LocalTool(ctx context.Context, inv Invocation) ([]byte, error) {
	tx, e := s.DB.Begin(ctx)
	if e != nil {
		return nil, e
	}
	defer tx.Rollback(ctx)
	r, e := checkInvocation(ctx, tx, inv)
	if e != nil {
		return nil, e
	}
	if e = authorize(r, inv); e != nil {
		return nil, e
	}
	old, status, e := existingCall(ctx, tx, inv)
	if e != nil {
		return nil, e
	}
	if status == "completed" {
		return old, tx.Commit(ctx)
	}
	if status != "" && status != "retryable" {
		return nil, ErrUnknown
	}
	var result any
	switch inv.Name {
	case "knowledge_search":
		var args struct{ Query, Kind string }
		if e = json.Unmarshal(inv.Arguments, &args); e == nil {
			result, e = searchDocuments(ctx, tx, args.Query, args.Kind, r.Snapshot.AgentRef.ID)
		}
	case "note_save":
		var d Document
		if e = json.Unmarshal(inv.Arguments, &d); e == nil {
			d.Scope = r.Snapshot.AgentRef.ID
			result, e = putDocument(ctx, tx, d)
		}
	case "document_read":
		var args struct {
			ID     string
			Offset int
			Limit  int
		}
		if e = json.Unmarshal(inv.Arguments, &args); e != nil {
			return nil, e
		}
		var d Document
		var metadata []byte
		e = tx.QueryRow(ctx, "SELECT id,kind,title,content,source,metadata,supersedes,scope,valid_until FROM documents WHERE id=$1 AND (scope='' OR scope=$2)", args.ID, r.Snapshot.AgentRef.ID).Scan(&d.ID, &d.Kind, &d.Title, &d.Content, &d.Source, &metadata, &d.Supersedes, &d.Scope, &d.ValidUntil)
		if e == nil {
			if e = json.Unmarshal(metadata, &d.Metadata); e != nil {
				return nil, e
			}
			chars := []rune(d.Content)
			if args.Offset > len(chars) {
				return nil, errors.New("offset exceeds document length")
			}
			if args.Limit == 0 {
				args.Limit = 1200
			}
			end := min(args.Offset+args.Limit, len(chars))
			d.Content = string(chars[args.Offset:end])
			result = map[string]any{"document": d, "next_offset": end, "has_more": end < len(chars), "total_characters": len(chars)}
		}
	case "artifact_read":
		var args struct {
			Hash   string
			Offset int
			Limit  int
		}
		if e = json.Unmarshal(inv.Arguments, &args); e != nil {
			return nil, e
		}
		var body []byte
		var media string
		e = tx.QueryRow(ctx, "SELECT body,media_type FROM artifacts WHERE hash=$1 FOR KEY SHARE", args.Hash).Scan(&body, &media)
		if e == nil {
			if Hash(body) != args.Hash {
				return nil, errors.New("artifact hash mismatch")
			}
			_, e = tx.Exec(ctx, "INSERT INTO artifact_refs(root,hash) VALUES($1,$2) ON CONFLICT DO NOTHING", "run:"+r.ID, args.Hash)
			chars := []rune(string(body))
			if args.Offset > len(chars) {
				return nil, errors.New("offset exceeds artifact length")
			}
			if args.Limit == 0 {
				args.Limit = 1200
			}
			end := args.Offset + args.Limit
			if end > len(chars) {
				end = len(chars)
			}
			result = map[string]any{"hash": args.Hash, "media_type": media, "content": string(chars[args.Offset:end]), "total_characters": len(chars), "next_offset": end, "has_more": end < len(chars)}
		}
	case "spawn_agent":
		var args struct {
			AgentID string `json:"agent_id"`
			Task    string `json:"task"`
		}
		if e = json.Unmarshal(inv.Arguments, &args); e != nil {
			return nil, e
		}
		child, ok := r.Snapshot.Children[args.AgentID]
		if !ok {
			return nil, errors.New("child agent not permitted by snapshot")
		}
		var n int
		if e = tx.QueryRow(ctx, "SELECT count(*) FROM runs WHERE parent_id=$1", r.ID).Scan(&n); e != nil {
			return nil, e
		}
		if n >= r.Snapshot.Agent.MaxChildren {
			return nil, errors.New("child agent budget exhausted")
		}
		var id string
		id, e = insertRun(ctx, tx, "spawn:"+inv.OperationID, args.Task, child, &r.ID, r.Constraints)
		result = map[string]string{"child_run_id": id}
	default:
		return nil, errors.New("not a local transactional tool")
	}
	if e != nil {
		return nil, e
	}
	body := JSON(result)
	if e = insertCall(ctx, tx, inv, "completed", body); e != nil {
		return nil, e
	}
	if e = event(ctx, tx, r.ID, "tool_completed", map[string]any{"operation_id": inv.OperationID, "name": inv.Name}); e != nil {
		return nil, e
	}
	return body, tx.Commit(ctx)
}
func (s *Store) ExternalTool(ctx context.Context, inv Invocation, execute func(context.Context, Run) ([]byte, error)) ([]byte, error) {
	tx, e := s.DB.Begin(ctx)
	if e != nil {
		return nil, e
	}
	defer tx.Rollback(ctx)
	r, e := checkInvocation(ctx, tx, inv)
	if e != nil {
		return nil, e
	}
	if e = authorize(r, inv); e != nil {
		return nil, e
	}
	old, status, e := existingCall(ctx, tx, inv)
	if e != nil {
		return nil, e
	}
	if status == "completed" {
		return old, tx.Commit(ctx)
	}
	retrySafe := inv.Name == "sandbox_exec" || inv.Name == "kb_search" // Sandbox reconciles deterministic ids; retrieval is read-only.
	if c, _, found := connectorForTool(r.Snapshot, inv.Name); found && c.ReadOnly {
		retrySafe = true
	}
	if (status == "inflight" || status == "unknown") && !retrySafe {
		_, e = tx.Exec(ctx, "UPDATE calls SET status='unknown',updated_at=now() WHERE id=$1", inv.OperationID)
		if e != nil {
			return nil, e
		}
		if e = tx.Commit(ctx); e != nil {
			return nil, e
		}
		return nil, ErrUnknown
	}
	if e = insertCall(ctx, tx, inv, "inflight", nil); e != nil {
		return nil, e
	}
	if e = event(ctx, tx, r.ID, "tool_started", map[string]any{"operation_id": inv.OperationID, "name": inv.Name}); e != nil {
		return nil, e
	}
	if e = tx.Commit(ctx); e != nil {
		return nil, e
	}
	result, execErr := execute(ctx, r)
	// An HTTP response alone is not a checkpoint. Persist it under the same valid fence first.
	tx, e = s.DB.Begin(ctx)
	if e != nil {
		return nil, e
	}
	defer tx.Rollback(ctx)
	if _, e = checkInvocation(ctx, tx, inv); e != nil {
		return nil, e
	}
	if execErr != nil {
		target := "unknown"
		if retrySafe {
			target = "retryable"
		}
		_, e = tx.Exec(ctx, "UPDATE calls SET status=$2,error=$3,updated_at=now() WHERE id=$1", inv.OperationID, target, execErr.Error())
		if e != nil {
			return nil, e
		}
		if e = event(ctx, tx, r.ID, "tool_"+target, map[string]any{"operation_id": inv.OperationID, "error": execErr.Error()}); e != nil {
			return nil, e
		}
		if e = tx.Commit(ctx); e != nil {
			return nil, e
		}
		if !retrySafe {
			return nil, ErrUnknown
		}
		return nil, execErr
	}
	if e = insertCall(ctx, tx, inv, "completed", result); e != nil {
		return nil, e
	}
	if e = event(ctx, tx, r.ID, "tool_completed", map[string]any{"operation_id": inv.OperationID, "name": inv.Name}); e != nil {
		return nil, e
	}
	return result, tx.Commit(ctx)
}
