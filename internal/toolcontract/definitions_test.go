package toolcontract

import "testing"

func TestBuiltinSchemasAreSelectedByName(t *testing.T) {
	for _, fixture := range []struct{ name, valid, invalid string }{
		{"sandbox_exec", `{"code":"console.log('fixture')"}`, `{"agent_id":"other","task":"do work"}`},
		{"knowledge_search", `{"query":"库存"}`, `{"query":"库存","unexpected":true}`},
		{"run_recall", `{"kind":"tools","operation_id":"run/dsh/1","limit":1200}`, `{"limit":1201}`},
	} {
		definition, err := Builtin(fixture.name)
		if err != nil {
			t.Fatal(err)
		}
		if err = ValidateArgs(definition, []byte(fixture.valid)); err != nil {
			t.Fatalf("%s rejected valid request: %v", fixture.name, err)
		}
		if err = ValidateArgs(definition, []byte(fixture.invalid)); err == nil {
			t.Fatalf("%s accepted wrong schema", fixture.name)
		}
	}
	if _, err := Builtin("unregistered"); err == nil {
		t.Fatal("unknown builtin accepted")
	}
}
