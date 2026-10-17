//go:build windows

// Synthetic process tree for Windows lifecycle tests. No platform credentials,
// database connection or model calls are involved.
package main

import (
	"encoding/json"
	"flag"
	"os"
	"os/exec"
	"time"
)

func main() {
	path := flag.String("config", "", "synthetic fixture configuration")
	flag.Parse()
	raw, err := os.ReadFile(*path)
	if err != nil {
		panic("cannot read fixture config")
	}
	var config map[string]string
	if json.Unmarshal(raw, &config) != nil {
		panic("invalid fixture config")
	}
	childID := 0
	if config["node"] != "" {
		child := exec.Command(config["node"], "--max-old-space-size=192", config["runner"])
		child.Stdout, child.Stderr = os.Stdout, os.Stderr
		if child.Start() != nil {
			panic("cannot start fixture child")
		}
		childID = child.Process.Pid
	}
	report, _ := json.Marshal(map[string]any{
		"pid": os.Getpid(), "child_pid": childID,
		"forbidden_environment_absent": os.Getenv("DATABASE_URL") == "" && os.Getenv("NODE_OPTIONS") == "" && os.Getenv("SERVICE_TOKEN") == "" && os.Getenv("AGENTOS_TEST_POISON") == "",
		"system_environment_present":   os.Getenv("SystemRoot") != "",
		"path":                         os.Getenv("PATH"),
	})
	if os.WriteFile(config["report"], report, 0600) != nil {
		panic("cannot write fixture report")
	}
	if config["exit"] == "1" {
		return
	}
	for {
		time.Sleep(time.Second)
	}
}
