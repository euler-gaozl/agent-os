// provision owns deployment identities and databases, never application DDL.
// This is for a NEW deployment. Historical upgrades use their recorded release
// and migration procedures; this command does not adopt existing installations.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"runtime"
	"time"
)

func main() {
	// The existing Windows release system already manages DACL-protected
	// configuration. This NEW Linux bootstrap does not claim Windows ACL support.
	if runtime.GOOS != "linux" {
		fmt.Fprintln(os.Stderr, "fresh deployment provisioning requires Linux; use the existing Windows platform maintenance tools for the installed system")
		os.Exit(2)
	}
	plan := flag.String("plan", "", "private new-deployment plan JSON")
	output := flag.String("output", "", "private deployment checkpoint/configuration directory")
	flag.Parse()
	if *plan == "" || *output == "" || flag.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "provide --plan and --output for a new deployment")
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	p, err := readPlan(*plan)
	if err == nil {
		err = provision(ctx, p, *output, nil)
	}
	if err != nil {
		// DB errors can contain credentials/queries. Do not print their text.
		fmt.Fprintln(os.Stderr, "provision failed; preserve the private checkpoint and verify plan, ownership, database access and configuration integrity before retrying")
		os.Exit(1)
	}
	fmt.Println("Deployment identities and domain databases verified; run each owner's migrator before starting services. No application schema was created.")
}
