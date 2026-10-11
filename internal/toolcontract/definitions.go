package toolcontract

import (
	"encoding/json"
	"errors"
	"fmt"
	. "github.com/euler-gaozl/agent-os/internal/contracts"
	"github.com/santhosh-tekuri/jsonschema/v6"
	"regexp"
	"strings"
)

func tool(name, description, schema string) Tool {
	return Tool{Name: name, Description: description, InputSchema: json.RawMessage(schema)}
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
func ConnectorForTool(snap Snapshot, name string) (Connector, string, bool) {
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
		if _, e := CompileSchema(t.InputSchema); e != nil {
			return nil, e
		}
	}
	return out, nil
}
func CompileSchema(b []byte) (*jsonschema.Schema, error) {
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
func ValidateArgs(t Tool, args []byte) error {
	var v any
	if e := json.Unmarshal(args, &v); e != nil {
		return e
	}
	schema, e := CompileSchema(t.InputSchema)
	if e != nil {
		return e
	}
	return schema.Validate(v)
}
