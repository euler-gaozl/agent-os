package platform

import (
	"context"
	"testing"
	"time"
)

// Measures the local durable lifecycle only; excludes model, tool, and network-provider latency.
func BenchmarkDurableTaskLifecycle(b *testing.B) {
	s, _ := testStore(b)
	ctx := context.Background()
	snap := basicSnapshot("http://127.0.0.1")
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, e := s.Submit(ctx, ID(), "benchmark fixture", snap, nil); e != nil {
			b.Fatal(e)
		}
		run, e := s.Claim(ctx, "benchmark", time.Minute)
		if e != nil {
			b.Fatal(e)
		}
		run.State.Result = "done"
		if e = s.Save(ctx, run, "completed"); e != nil {
			b.Fatal(e)
		}
	}
}
