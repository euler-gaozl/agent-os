package platform

import (
	"context"
	"testing"
)

func TestSelectedServiceMigrationDoesNotTouchOtherDomains(t *testing.T) {
	s, _ := testStore(t)
	ctx := context.Background()
	// Missing objects are canaries: a hidden full-platform migration would
	// recreate them and this test would fail.
	if _, e := s.DB.Exec(ctx, "DROP TABLE sandbox_jobs; DROP TABLE knowledge_chunks"); e != nil {
		t.Fatal(e)
	}
	if e := MigrateService(ctx, s.DB, "registry"); e != nil {
		t.Fatal(e)
	}
	var untouched bool
	if e := s.DB.QueryRow(ctx, "SELECT to_regclass(current_schema()||'.sandbox_jobs') IS NULL AND to_regclass(current_schema()||'.knowledge_chunks') IS NULL").Scan(&untouched); e != nil || !untouched {
		t.Fatal("registry migration touched unrelated schemas", e)
	}
	if e := MigrateService(ctx, s.DB, "sandbox"); e != nil {
		t.Fatal(e)
	}
	if e := s.DB.QueryRow(ctx, "SELECT to_regclass(current_schema()||'.sandbox_jobs') IS NOT NULL AND to_regclass(current_schema()||'.knowledge_chunks') IS NULL").Scan(&untouched); e != nil || !untouched {
		t.Fatal("sandbox migration crossed ownership boundary", e)
	}
	if e := MigrateService(ctx, s.DB, "worker"); e != nil {
		t.Fatal(e)
	}
	if e := MigrateService(ctx, s.DB, "unknown"); e == nil {
		t.Fatal("invalid migration owner was accepted")
	}
}
