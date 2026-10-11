package platform

import (
	"context"
	"encoding/json"
	"github.com/jackc/pgx/v5"
)

// Publication is part of the immutable Agent version, not a second business resource.
func migratePublications(ctx context.Context, tx pgx.Tx) error {
	var exists bool
	if e := tx.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM schema_versions WHERE version=4)").Scan(&exists); e != nil {
		return e
	}
	if exists {
		return nil
	}
	rows, e := tx.Query(ctx, `SELECT DISTINCT ON(id) id,spec FROM resources WHERE kind='action' ORDER BY id,revision DESC`)
	if e != nil {
		return e
	}
	type legacy struct {
		id string
		a  BusinessAction
	}
	list := []legacy{}
	for rows.Next() {
		var id string
		var spec []byte
		if e = rows.Scan(&id, &spec); e != nil {
			rows.Close()
			return e
		}
		var a BusinessAction
		if e = json.Unmarshal(spec, &a); e != nil {
			rows.Close()
			return e
		}
		list = append(list, legacy{id, a})
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return e
	}
	for _, old := range list {
		var raw []byte
		if e = tx.QueryRow(ctx, "SELECT spec FROM resources WHERE kind='agent' AND id=$1 AND revision=$2", old.a.Agent.ID, old.a.Agent.Revision).Scan(&raw); e != nil {
			return e
		}
		var a Agent
		if e = json.Unmarshal(raw, &a); e != nil {
			return e
		}
		a.Name = old.a.Name
		a.Prompt += "\n\n" + old.a.Instruction
		a.Constraints = append(a.Constraints, old.a.Constraints...)
		a.Publication = Publication{Enabled: true, App: "futures", Name: old.a.Name, Description: old.a.Description}
		if e = a.Validate(); e != nil {
			return e
		}
		if _, e = tx.Exec(ctx, "INSERT INTO resources(kind,id,revision,spec) VALUES('agent',$1,1,$2)", "published-"+old.id, JSON(a)); e != nil {
			return e
		}
	}
	_, e = tx.Exec(ctx, "INSERT INTO schema_versions(version) VALUES(4)")
	return e
}
