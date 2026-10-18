// Windows Job root for opt-in acceptance. Retains the inherited Job handle while
// Go test runs; root exit kills remaining descendants, including Node.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

func main() {
	p := flag.String("config", "", "fixture controller configuration")
	flag.Parse()
	var c struct{ Go, Binary, Directory, Timeout string }
	b, e := os.ReadFile(*p)
	if e != nil || json.Unmarshal(b, &c) != nil || (c.Timeout != "8m" && c.Timeout != "4s") {
		fmt.Fprintln(os.Stderr, "invalid fixture controller configuration")
		os.Exit(2)
	}
	cmd := exec.Command(c.Go, "tool", "test2json", "-t", "-p", "github.com/euler-gaozl/agent-os/scripts/acceptance/resident", c.Binary, "-test.v=test2json", "-test.timeout="+c.Timeout)
	cmd.Dir, cmd.Stdout, cmd.Stderr = c.Directory, os.Stdout, os.Stderr
	code := 0
	if e = cmd.Run(); e != nil {
		if x, ok := e.(*exec.ExitError); ok {
			code = x.ExitCode()
		} else {
			fmt.Fprintln(os.Stderr, "fixture test process unavailable")
			code = 2
		}
	}
	report, _ := json.Marshal(map[string]any{"exit_code": code, "finished_at": time.Now()})
	if e = os.WriteFile(filepath.Join(filepath.Dir(*p), "controller-result.json"), report, 0600); e != nil {
		os.Exit(2)
	}
	os.Exit(code)
}
