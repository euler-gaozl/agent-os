package servicehost

import (
	"testing"
)

func TestMemoryBudgetFromConfiguration(t *testing.T) {
	for value, want := range map[string]int64{"96MiB": 96 << 20, "1GiB": 1 << 30} {
		got, e := memoryLimit(value)
		if e != nil || got != want {
			t.Fatal(got, e)
		}
	}
	for _, value := range []string{"-1MiB", "999999999999999GiB", "0MiB", "garbage"} {
		if _, e := memoryLimit(value); e == nil {
			t.Fatal("accepted", value)
		}
	}
}
