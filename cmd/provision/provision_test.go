package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func fixturePlan() plan {
	p := plan{Format: 1, Prefix: "agentos_test_unit", AdminDatabaseURL: "postgres://provision_fixture:fixture-only@127.0.0.1:55592/postgres?sslmode=disable", AdminToken: strings.Repeat("a", 40), BusinessToken: strings.Repeat("b", 40), MasterKey: strings.Repeat("c", 64), Endpoints: map[string]string{}}
	for _, r := range roles {
		p.Endpoints[r] = "http://" + r + ":8090"
	}
	return p
}
func TestPrivatePlanInput(t *testing.T) {
	file := filepath.Join(t.TempDir(), "plan.json")
	b, err := json.Marshal(fixturePlan())
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(file, b, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = readPlan(file); err != nil {
		t.Fatal(err)
	}
	for _, invalid := range [][]byte{append(append([]byte{}, b...), []byte(" {}")...), append(append([]byte{}, b...), bytes.Repeat([]byte(" "), 65536)...)} {
		if err = os.WriteFile(file, invalid, 0600); err != nil {
			t.Fatal(err)
		}
		if _, err = readPlan(file); err == nil {
			t.Fatal("invalid or unbounded plan accepted")
		}
	}
	if runtime.GOOS != "windows" {
		if err = os.WriteFile(file, b, 0600); err != nil {
			t.Fatal(err)
		}
		if err = os.Chmod(file, 0644); err != nil {
			t.Fatal(err)
		}
		if _, err = readPlan(file); err == nil {
			t.Fatal("public credential plan accepted")
		}
		link := filepath.Join(filepath.Dir(file), "link.json")
		if err = os.Symlink(file, link); err != nil {
			t.Fatal(err)
		}
		if _, err = readPlan(link); err == nil {
			t.Fatal("symlink plan accepted")
		}
	}
}
func TestProvisionPlanAndIdentityIsolation(t *testing.T) {
	p := fixturePlan()
	if err := p.validate(); err != nil {
		t.Fatal(err)
	}
	s, err := newCheckpoint(p, "1234")
	if err != nil {
		t.Fatal(err)
	}
	if err = s.validate(p, "1234"); err != nil {
		t.Fatal(err)
	}
	configs, targets := configurations(p, s)
	if len(targets) != 8 {
		t.Fatal("domain mapping differs")
	}
	for _, role := range roles {
		c := configs[role]
		if (c["MASTER_KEY"] != "") != (role == "registry") || (c["ADMIN_TOKEN"] != "") != (role == "control") || (c["BUSINESS_TOKEN"] != "") != (role == "futures") {
			t.Fatal("credential leaked across service boundary")
		}
		if (c["DATABASE_URL"] != "") != (domain(role) != "") {
			t.Fatal("database ownership differs")
		}
		if domain(role) != "" {
			u, _ := url.Parse(c["DATABASE_URL"])
			if u.User.Username() != p.Prefix+"_"+role || u.Path != "/"+p.Prefix+"_"+domain(role) {
				t.Fatal("DSN identity differs")
			}
		}
	}
	for _, mutate := range []func(*plan){
		func(p *plan) {
			p.AdminDatabaseURL = strings.Replace(p.AdminDatabaseURL, "/postgres?", "/template1?", 1)
		},
		func(p *plan) { p.AdminDatabaseURL += "&user=postgres" },
		func(p *plan) { p.AdminDatabaseURL += "&options=-c%20role%3Dpostgres" },
		func(p *plan) { p.AdminDatabaseURL += "&sslmode=require" },
		func(p *plan) { p.Prefix = "agentos_x;drop" },
		func(p *plan) { p.BusinessToken = p.AdminToken },
		func(p *plan) { p.Endpoints["runtime"] = "http://user:password@runtime:8094" },
		func(p *plan) { p.Options = map[string]map[string]string{"worker": {"MASTER_KEY": "forbidden"}} },
	} {
		copy := fixturePlan()
		mutate(&copy)
		if copy.validate() == nil {
			t.Fatal("unsafe plan accepted")
		}
	}
	if s.validate(p, "other-cluster") == nil {
		t.Fatal("reinitialized cluster accepted")
	}
}
func TestProvisionDatabaseRecovery(t *testing.T) {
	dsn := os.Getenv("TEST_PROVISION_DATABASE_URL")
	if dsn == "" {
		t.Skip("set TEST_PROVISION_DATABASE_URL to a disposable SCRAM PostgreSQL cluster")
	}
	if os.Getenv("TEST_PROVISION_ALLOW_CREATE") != "1" {
		t.Fatal("explicit disposable fixture opt-in required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	admin, err := connect(ctx, dsn)
	if err != nil {
		t.Fatal("fixture connection failed")
	}
	defer admin.Close(context.Background())
	var user, db string
	if err = admin.QueryRow(ctx, "SELECT current_user,current_database()").Scan(&user, &db); err != nil || user != "provision_fixture" || db != "postgres" {
		t.Fatal("fixture identity must be provision_fixture in postgres")
	}
	id, err := randomID()
	if err != nil {
		t.Fatal(err)
	}
	p := fixturePlan()
	p.Prefix = "agentos_test_" + id[:12]
	p.AdminDatabaseURL = dsn
	root := filepath.Join(t.TempDir(), "private")
	if err = os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	// Cleanup is restricted to this generated disposable prefix. No production
	// database, real platform configuration, or existing service is touched.
	defer func() {
		clean, c := context.WithTimeout(context.Background(), 30*time.Second)
		defer c()
		for _, d := range domains {
			_, e := admin.Exec(clean, "DROP DATABASE IF EXISTS "+pgx.Identifier{p.Prefix + "_" + d}.Sanitize()+" WITH (FORCE)")
			if e != nil {
				t.Error("fixture database cleanup failed")
			}
		}
		for _, role := range append(append([]string{}, roles...), "owner") {
			if domain(role) == "" {
				continue
			}
			_, e := admin.Exec(clean, "DROP ROLE IF EXISTS "+pgx.Identifier{p.Prefix + "_" + role}.Sanitize())
			if e != nil {
				t.Error("fixture role cleanup failed")
			}
		}
	}()
	interrupted := errors.New("injected stop")
	read := func(name string) []byte {
		b, e := readPrivate(filepath.Join(root, name))
		if e != nil {
			t.Fatal("private fixture file missing")
		}
		return b
	}
	var original map[string][]byte
	for _, phase := range []string{"checkpoint", "role:" + p.Prefix + "_owner", "role:" + p.Prefix + "_runtime", "database:registry", "acl:registry", "database:runtime", "acl:sources", "publish"} {
		hit := false
		err = provision(ctx, p, root, func(at string) error {
			if at == phase {
				if phase == "checkpoint" {
					if provision(ctx, p, root, nil) == nil {
						t.Fatal("concurrent checkpoint writer accepted")
					}
					if e := provision(ctx, p, filepath.Join(t.TempDir(), "second"), nil); e == nil || !strings.Contains(e.Error(), "being provisioned") {
						t.Fatal("concurrent deployment accepted from another directory")
					}
				}
				hit = true
				return interrupted
			}
			return nil
		})
		if !hit || !errors.Is(err, interrupted) {
			t.Fatalf("fault boundary did not execute: %s", phase)
		}
		if _, err = os.Stat(filepath.Join(root, "ready.json")); !os.IsNotExist(err) {
			t.Fatal("partial bootstrap published readiness")
		}
		if original == nil {
			original = map[string][]byte{}
			for _, role := range roles {
				original[role] = read(role + ".json")
			}
		}
		for _, role := range roles {
			if !bytes.Equal(original[role], read(role+".json")) {
				t.Fatal("retry rotated configuration")
			}
		}
		if phase == "database:registry" {
			var accepts bool
			if err = admin.QueryRow(ctx, "SELECT datallowconn FROM pg_database WHERE datname=$1", p.Prefix+"_registry").Scan(&accepts); err != nil || accepts {
				t.Fatal("new database was accessible before ACL commit")
			}
		}
		if phase == "checkpoint" {
			killed := false
			e := provision(ctx, p, root, func(at string) error {
				if at == "checkpoint" {
					e := admin.QueryRow(ctx, "SELECT pg_terminate_backend(pid) FROM pg_locks WHERE locktype='advisory' AND classid=812321 AND objid=hashtext($1)::oid AND granted", p.Prefix).Scan(&killed)
					if e != nil || !killed {
						t.Fatal("fixture maintenance connection was not terminated")
					}
				}
				return nil
			})
			if e == nil || !killed {
				t.Fatal("provision continued after maintenance connection loss")
			}
		}
	}
	if err = provision(ctx, p, root, nil); err != nil {
		t.Fatal("resumed provision failed")
	}
	initial := read("provision.json")
	ready := read("ready.json")
	if err = provision(ctx, p, root, nil); err != nil {
		t.Fatal("idempotent provision failed")
	}
	if !bytes.Equal(initial, read("provision.json")) || !bytes.Equal(ready, read("ready.json")) {
		t.Fatal("complete retry changed publication")
	}
	var state checkpoint
	if err = json.Unmarshal(initial, &state); err != nil {
		t.Fatal(err)
	}
	for _, role := range roles {
		if domain(role) == "" {
			continue
		}
		for _, d := range domains {
			var allowed bool
			err = admin.QueryRow(ctx, "SELECT has_database_privilege($1,$2,'CONNECT')", p.Prefix+"_"+role, p.Prefix+"_"+d).Scan(&allowed)
			if err != nil || allowed != (domain(role) == d) {
				t.Fatal("cross-domain database grant differs")
			}
		}
	}
	for _, d := range domains {
		u, _ := url.Parse(dsn)
		u.Path = "/" + p.Prefix + "_" + d
		c, e := connect(ctx, u.String())
		if e != nil {
			t.Fatal("cannot inspect provisioned domain")
		}
		var count int
		e = c.QueryRow(ctx, "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN('pg_catalog','information_schema')").Scan(&count)
		_ = c.Close(ctx)
		if e != nil || count != 0 {
			t.Fatal("provision created application tables")
		}
	}
	// Reconstruct a missing service config from the same saved identity.
	if err = os.Remove(filepath.Join(root, "worker.json")); err != nil {
		t.Fatal(err)
	}
	if err = provision(ctx, p, root, nil); err != nil || !bytes.Equal(original["worker"], read("worker.json")) {
		t.Fatal("missing config did not recover unchanged")
	}
	changed := p
	changed.BusinessToken = strings.Repeat("d", 40)
	if provision(ctx, changed, root, nil) == nil {
		t.Fatal("plan drift accepted")
	}
	if err = os.WriteFile(filepath.Join(root, "worker.json"), []byte("{}"), 0600); err != nil {
		t.Fatal(err)
	}
	if provision(ctx, p, root, nil) == nil {
		t.Fatal("configuration drift accepted")
	}
	if err = os.WriteFile(filepath.Join(root, "worker.json"), original["worker"], 0600); err != nil {
		t.Fatal(err)
	}
	worker := pgx.Identifier{p.Prefix + "_worker"}.Sanitize()
	registryDB := pgx.Identifier{p.Prefix + "_registry"}.Sanitize()
	if _, err = admin.Exec(ctx, "GRANT CONNECT ON DATABASE "+registryDB+" TO "+worker); err != nil {
		t.Fatal("fixture cross-domain grant failed")
	}
	if err = provision(ctx, p, root, nil); err == nil || !strings.Contains(err.Error(), "database ACL drift") {
		t.Fatal("extra database CONNECT grant was accepted")
	}
	var retained bool
	if err = admin.QueryRow(ctx, "SELECT has_database_privilege($1,$2,'CONNECT')", p.Prefix+"_worker", p.Prefix+"_registry").Scan(&retained); err != nil || !retained {
		t.Fatal("provision silently changed drifted ACL")
	}
	if _, err = admin.Exec(ctx, "REVOKE CONNECT ON DATABASE "+registryDB+" FROM "+worker); err != nil {
		t.Fatal("fixture grant restoration failed")
	}
	if _, err = admin.Exec(ctx, "ALTER DATABASE "+registryDB+" ALLOW_CONNECTIONS=false"); err != nil {
		t.Fatal("fixture database pause failed")
	}
	if err = provision(ctx, p, root, nil); err == nil || !strings.Contains(err.Error(), "database connection policy drift") {
		t.Fatal("paused database was silently enabled")
	}
	if err = admin.QueryRow(ctx, "SELECT datallowconn FROM pg_database WHERE datname=$1", p.Prefix+"_registry").Scan(&retained); err != nil || retained {
		t.Fatal("provision changed operator database pause")
	}
	if _, err = admin.Exec(ctx, "ALTER DATABASE "+registryDB+" ALLOW_CONNECTIONS=true"); err != nil {
		t.Fatal("fixture pause restoration failed")
	}
	if _, err = admin.Exec(ctx, "ALTER ROLE "+worker+" CREATEDB"); err != nil {
		t.Fatal("fixture privilege mutation failed")
	}
	if provision(ctx, p, root, nil) == nil {
		t.Fatal("role privilege drift accepted")
	}
	var elevated bool
	_ = admin.QueryRow(ctx, "SELECT rolcreatedb FROM pg_roles WHERE rolname=$1", p.Prefix+"_worker").Scan(&elevated)
	if !elevated {
		t.Fatal("provision silently repaired unauthorized privilege drift")
	}
	if _, err = admin.Exec(ctx, "ALTER ROLE "+worker+" NOCREATEDB PASSWORD 'fixture-password-drift'"); err != nil {
		t.Fatal("fixture password mutation failed")
	}
	if provision(ctx, p, root, nil) == nil {
		t.Fatal("password drift accepted")
	}
	if _, err = admin.Exec(ctx, "ALTER ROLE "+worker+" PASSWORD '"+state.Passwords["worker"]+"'"); err != nil {
		t.Fatal("fixture password restoration failed")
	}
	// OID replacement with the same owner and marker must still be rejected.
	name := p.Prefix + "_sources"
	ident := pgx.Identifier{name}.Sanitize()
	if _, err = admin.Exec(ctx, "DROP DATABASE "+ident); err != nil {
		t.Fatal("fixture drop failed")
	}
	if _, err = admin.Exec(ctx, "CREATE DATABASE "+ident+" OWNER "+pgx.Identifier{p.Prefix + "_owner"}.Sanitize()+" TEMPLATE template0"); err != nil {
		t.Fatal("fixture recreation failed")
	}
	if _, err = admin.Exec(ctx, "COMMENT ON DATABASE "+ident+" IS 'agent-os provision "+state.ID+"'"); err != nil {
		t.Fatal("fixture marker failed")
	}
	if err = provision(ctx, p, root, nil); err == nil || !strings.Contains(err.Error(), "database identity differs") {
		t.Fatal("database OID replacement was not rejected")
	}
	if _, err = admin.Exec(ctx, "DROP DATABASE "+ident); err != nil {
		t.Fatal("fixture drop failed")
	}
	if err = provision(ctx, p, root, nil); err == nil || !strings.Contains(err.Error(), "confirmed database disappeared") {
		t.Fatal("confirmed missing database was recreated")
	}
	// Same named deployment, absent checkpoint, may not adopt any existing role.
	if err = provision(ctx, p, filepath.Join(t.TempDir(), "unmanaged"), nil); err == nil || !strings.Contains(err.Error(), "without checkpoint") {
		t.Fatal("existing deployment adopted without checkpoint")
	}
	if _, err = admin.Exec(ctx, "REVOKE ALL ON DATABASE "+pgx.Identifier{p.Prefix + "_runtime"}.Sanitize()+" FROM "+worker); err != nil {
		t.Fatal("fixture role privilege removal failed")
	}
	if _, err = admin.Exec(ctx, "DROP ROLE "+worker); err != nil {
		t.Fatal("fixture role drop failed")
	}
	if _, err = admin.Exec(ctx, "CREATE ROLE "+worker+" LOGIN PASSWORD '"+state.Passwords["worker"]+"'"); err != nil {
		t.Fatal("fixture role recreation failed")
	}
	if _, err = admin.Exec(ctx, "COMMENT ON ROLE "+worker+" IS 'agent-os provision "+state.ID+"'"); err != nil {
		t.Fatal("fixture role marker failed")
	}
	if err = provision(ctx, p, root, nil); err == nil || !strings.Contains(err.Error(), "managed role integrity differs") {
		t.Fatal("same-name role with another OID was accepted")
	}
}
