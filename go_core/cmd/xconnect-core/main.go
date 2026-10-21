// xconnect-core is the Windows desktop runtime for XConnect. It links the
// libXray package directly and keeps the core in its own process, preventing
// the runtime's buffers and goroutines from sharing the Flutter process lifetime.
package main

import (
	"flag"
	"fmt"
	"os"

	"go_core/internal/corestatus"

	"github.com/xtls/libxray/xray"
)

func main() {
	configPath := flag.String("config", "", "path to the Xray JSON configuration")
	statusPath := flag.String("startup-status", "", "path to the startup state file")
	flag.Parse()
	if *configPath == "" {
		fmt.Fprintln(os.Stderr, "missing -config")
		os.Exit(2)
	}

	if err := xray.RunXray(*configPath); err != nil {
		if *statusPath != "" {
			_ = corestatus.Write(*statusPath, corestatus.Failure(err))
		}
		// Full engine errors can include configuration values. Return only a
		// stage and an optional system error code to the parent.
		fmt.Fprintln(os.Stderr, "core_start_failed")
		os.Exit(1)
	}

	if *statusPath != "" {
		if err := corestatus.Write(*statusPath, corestatus.Status{Phase: "ready"}); err != nil {
			_ = xray.StopXray()
			os.Exit(1)
		}
	}

	// The parent owns this process and stops it with the Windows process
	// handle.  Keep the process alive until that happens; Xray itself runs its
	// workers asynchronously after RunXray returns.
	select {}
}
