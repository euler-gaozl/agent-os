package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func connect(ctx context.Context, dsn string) (*pgx.Conn, error) {
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, errors.New("invalid deployment connection")
	}
	cfg.ConnectTimeout = 5 * time.Second
	cfg.RuntimeParams["statement_timeout"] = "30000"
	cfg.RuntimeParams["lock_timeout"] = "3000"
	return pgx.ConnectConfig(ctx, cfg)
}
func provision(ctx context.Context, p plan, output string, after func(string) error) error {
	if err := p.validate(); err != nil {
		return err
	}
	root, err := privateDirectory(output)
	if err != nil {
		return err
	}
	unlock, err := lockCheckpoint(filepath.Join(root, ".provision.lock"))
	if err != nil {
		return errors.New("checkpoint directory is locked")
	}
	defer unlock()
	admin, err := connect(ctx, p.AdminDatabaseURL)
	if err != nil {
		return err
	}
	defer admin.Close(context.Background())
	var locked bool
	if err = admin.QueryRow(ctx, "SELECT pg_try_advisory_lock(812321,hashtext($1))", p.Prefix).Scan(&locked); err != nil {
		return err
	}
	if !locked {
		return errors.New("deployment is being provisioned")
	}
	var cluster string
	if err = admin.QueryRow(ctx, "SELECT system_identifier::text FROM pg_control_system()").Scan(&cluster); err != nil {
		return err
	}
	file := filepath.Join(root, "provision.json")
	raw, err := readPrivate(file)
	var state checkpoint
	if os.IsNotExist(err) {
		// No adoption: reject even an empty existing database or login identity.
		for _, role := range append([]string{"owner"}, roles...) {
			if domain(role) == "" {
				continue
			}
			var exists bool
			if err = admin.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=$1)", p.Prefix+"_"+role).Scan(&exists); err != nil {
				return err
			}
			if exists {
				return errors.New("deployment role exists without checkpoint")
			}
		}
		for _, d := range domains {
			var exists bool
			if err = admin.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname=$1)", p.Prefix+"_"+d).Scan(&exists); err != nil {
				return err
			}
			if exists {
				return errors.New("deployment database exists without checkpoint")
			}
		}
		state, err = newCheckpoint(p, cluster)
		if err != nil {
			return err
		}
		if err = writeExact(file, state); err != nil {
			return err
		}
	} else if err != nil {
		return err
	} else if err = json.Unmarshal(raw, &state); err != nil {
		return err
	}
	if err = state.validate(p, cluster); err != nil {
		return err
	}
	raw, err = readPrivate(file)
	if err != nil {
		return err
	}
	checkpointHash := hash(raw)
	save := func() error {
		if err := admin.Ping(ctx); err != nil {
			return err
		}
		return saveCheckpoint(file, state, &checkpointHash)
	}
	configs, targets := configurations(p, state)
	// Materialize every private identity before making corresponding DB changes.
	// Retry compares exact bytes. External edits are not silently overwritten.
	if err = writeExact(filepath.Join(root, "identities.json"), state.Identities); err != nil {
		return err
	}
	for _, role := range roles {
		if err = writeExact(filepath.Join(root, role+".json"), configs[role]); err != nil {
			return err
		}
	}
	if err = writeExact(filepath.Join(root, "migration-targets.json"), targets); err != nil {
		return err
	}
	if after != nil {
		if err = after("checkpoint"); err != nil {
			return err
		}
	}
	owner := p.Prefix + "_owner"
	ensure := func(name, password string) error {
		expected, exists := state.Roles[name]
		if !exists {
			state.Roles[name] = 0
			if err := save(); err != nil {
				return err
			}
		}
		oid, err := ensureRole(ctx, admin, name, password, state.ID, expected)
		if err != nil {
			return err
		}
		if after != nil {
			if err = after("role:" + name); err != nil {
				return err
			}
		}
		state.Roles[name] = oid
		return save()
	}
	if err = ensure(owner, ""); err != nil {
		return err
	}
	for _, role := range roles {
		if domain(role) != "" {
			if err = ensure(p.Prefix+"_"+role, state.Passwords[role]); err != nil {
				return err
			}
		}
	}
	for _, t := range targets {
		expected, intent := state.Databases[t.Database]
		if !intent {
			state.Databases[t.Database] = 0
			if err = save(); err != nil {
				return err
			}
		}
		var owned bool
		var oid uint32
		var comment string
		err = admin.QueryRow(ctx, "SELECT oid,datdba=(SELECT oid FROM pg_roles WHERE rolname=$2),coalesce(shobj_description(oid,'pg_database'),'') FROM pg_database WHERE datname=$1", t.Database, owner).Scan(&oid, &owned, &comment)
		if errors.Is(err, pgx.ErrNoRows) {
			if expected != 0 {
				return errors.New("confirmed database disappeared")
			}
			// CREATE DATABASE cannot be transactional. Its unique NOLOGIN owner
			// establishes durable attribution even if the reply is lost.
			_, err = admin.Exec(ctx, "CREATE DATABASE "+pgx.Identifier{t.Database}.Sanitize()+" OWNER "+pgx.Identifier{owner}.Sanitize()+" TEMPLATE template0 ALLOW_CONNECTIONS=false")
			if err != nil {
				return err
			}
			owned = true
			if err = admin.QueryRow(ctx, "SELECT oid FROM pg_database WHERE datname=$1", t.Database).Scan(&oid); err != nil {
				return err
			}
		} else if err != nil {
			return err
		}
		wantComment := "agent-os provision " + state.ID
		if !owned || (expected != 0 && oid != expected) || (comment != "" && comment != wantComment) || (expected != 0 && comment != wantComment) {
			return errors.New("database identity differs")
		}
		if comment == wantComment {
			// Confirmed ACLs are read-only on retry. Do not quietly undo an
			// operator pause or accept an extra cross-domain CONNECT grant.
			if err = verifyDatabaseACL(ctx, admin, t, state, false); err != nil {
				return err
			}
			state.Databases[t.Database] = oid
			if err = save(); err != nil {
				return err
			}
			continue
		}
		if err = verifyDatabaseACL(ctx, admin, t, state, true); err != nil {
			return err
		}
		if after != nil {
			if err = after("database:" + t.Owner); err != nil {
				return err
			}
		}
		tx, err := admin.Begin(ctx)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, "REVOKE ALL ON DATABASE "+pgx.Identifier{t.Database}.Sanitize()+" FROM PUBLIC")
		if err == nil {
			for _, role := range t.Roles {
				_, err = tx.Exec(ctx, "GRANT CONNECT ON DATABASE "+pgx.Identifier{t.Database}.Sanitize()+" TO "+pgx.Identifier{role}.Sanitize())
				if err != nil {
					break
				}
			}
		}
		if err == nil {
			_, err = tx.Exec(ctx, "COMMENT ON DATABASE "+pgx.Identifier{t.Database}.Sanitize()+" IS '"+wantComment+"'")
		}
		if err == nil {
			_, err = tx.Exec(ctx, "ALTER DATABASE "+pgx.Identifier{t.Database}.Sanitize()+" ALLOW_CONNECTIONS=true")
		}
		if err == nil {
			err = tx.Commit(ctx)
		} else {
			_ = tx.Rollback(ctx)
		}
		if err != nil {
			return err
		}
		if err = verifyDatabaseACL(ctx, admin, t, state, false); err != nil {
			return err
		}
		if after != nil {
			if err = after("acl:" + t.Owner); err != nil {
				return err
			}
		}
		state.Databases[t.Database] = oid
		if err = save(); err != nil {
			return err
		}
	}
	// A retained role's password may have changed outside this coordinator.
	// Detect that by real authentication; never ALTER it to hide the change.
	for _, role := range roles {
		if domain(role) == "" {
			continue
		}
		c, err := connect(ctx, configs[role]["DATABASE_URL"])
		if err != nil {
			return err
		}
		var actualUser, actualDB string
		err = c.QueryRow(ctx, "SELECT current_user,current_database()").Scan(&actualUser, &actualDB)
		_ = c.Close(ctx)
		if err != nil {
			return err
		}
		if actualUser != p.Prefix+"_"+role || actualDB != p.Prefix+"_"+domain(role) {
			return errors.New("application identity differs")
		}
		wrong := state
		wrong.Passwords = map[string]string{role: state.Passwords[role] + "wrong"}
		unexpected, err := connect(ctx, applicationURL(p, wrong, role))
		if err == nil {
			_ = unexpected.Close(ctx)
			return errors.New("server does not enforce password authentication")
		}
		var authentication *pgconn.PgError
		if !errors.As(err, &authentication) || authentication.Code != "28P01" {
			return errors.New("password rejection was not verified")
		}
	}
	if err = admin.Ping(ctx); err != nil {
		return err
	}
	state.Complete = true
	if err = save(); err != nil {
		return err
	}
	if after != nil {
		if err = after("publish"); err != nil {
			return err
		}
	}
	if err = writeExact(filepath.Join(root, "ready.json"), map[string]any{"format": 1, "prefix": p.Prefix, "cluster_id": cluster, "checkpoint_sha256": checkpointHash, "application_migrations": "not performed"}); err != nil {
		return err
	}
	return nil
}
func verifyDatabaseACL(ctx context.Context, admin *pgx.Conn, t target, state checkpoint, initial bool) error {
	var allows bool
	if err := admin.QueryRow(ctx, "SELECT datallowconn FROM pg_database WHERE datname=$1", t.Database).Scan(&allows); err != nil {
		return err
	}
	if allows == initial {
		return errors.New("database connection policy drift")
	}
	type permission struct {
		grantee   uint32
		privilege string
	}
	owner := state.Roles[state.Prefix+"_owner"]
	expected := map[permission]bool{{owner, "CREATE"}: true, {owner, "CONNECT"}: true, {owner, "TEMPORARY"}: true}
	if initial {
		expected[permission{0, "CONNECT"}] = true
		expected[permission{0, "TEMPORARY"}] = true
	} else {
		for _, name := range t.Roles {
			expected[permission{state.Roles[name], "CONNECT"}] = true
		}
	}
	rows, err := admin.Query(ctx, "SELECT a.grantor,a.grantee,a.privilege_type,a.is_grantable FROM pg_database d CROSS JOIN LATERAL aclexplode(coalesce(d.datacl,acldefault('d',d.datdba))) a WHERE d.datname=$1", t.Database)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var grantor, grantee uint32
		var privilege string
		var grantable bool
		if err = rows.Scan(&grantor, &grantee, &privilege, &grantable); err != nil {
			return err
		}
		key := permission{grantee, privilege}
		if grantor != owner || grantable || !expected[key] {
			return errors.New("database ACL drift")
		}
		delete(expected, key)
	}
	if err = rows.Err(); err != nil {
		return err
	}
	if len(expected) != 0 {
		return errors.New("database ACL incomplete")
	}
	return nil
}
func ensureRole(ctx context.Context, admin *pgx.Conn, name, password, id string, expected uint32) (uint32, error) {
	tx, err := admin.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)
	var login, super, createdb, createrole, replication, bypass bool
	var marker string
	var memberships int
	var oid uint32
	err = tx.QueryRow(ctx, "SELECT oid,rolcanlogin,rolsuper,rolcreatedb,rolcreaterole,rolreplication,rolbypassrls,coalesce(shobj_description(oid,'pg_authid'),''),(SELECT count(*) FROM pg_auth_members WHERE member=r.oid OR roleid=r.oid) FROM pg_roles r WHERE rolname=$1", name).Scan(&oid, &login, &super, &createdb, &createrole, &replication, &bypass, &marker, &memberships)
	want := "agent-os provision " + id
	if errors.Is(err, pgx.ErrNoRows) {
		if expected != 0 {
			return 0, errors.New("confirmed role disappeared")
		}
		mode := "NOLOGIN"
		if password != "" {
			mode = "LOGIN PASSWORD '" + password + "'"
		} // password is validated random hex, never input SQL.
		if _, err = tx.Exec(ctx, "CREATE ROLE "+pgx.Identifier{name}.Sanitize()+" "+mode+" NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS"); err != nil {
			return 0, err
		}
		if _, err = tx.Exec(ctx, "COMMENT ON ROLE "+pgx.Identifier{name}.Sanitize()+" IS '"+want+"'"); err != nil {
			return 0, err
		}
		if err = tx.QueryRow(ctx, "SELECT oid FROM pg_roles WHERE rolname=$1", name).Scan(&oid); err != nil {
			return 0, err
		}
	} else if err != nil {
		return 0, err
	} else if (expected != 0 && oid != expected) || login != (password != "") || super || createdb || createrole || replication || bypass || marker != want || memberships != 0 {
		return 0, errors.New("managed role integrity differs")
	}
	return oid, tx.Commit(ctx)
}
