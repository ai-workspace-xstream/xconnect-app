// xconnect-core is the Windows desktop runtime for XConnect.  It deliberately
// links the libXray package directly instead of using vendor/Xray-core as a
// second application runtime.  Keeping the core in its own process prevents
// Xray's buffers and goroutines from sharing the Flutter process lifetime.
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/xtls/libxray/xray"
)

func main() {
	configPath := flag.String("config", "", "path to the Xray JSON configuration")
	flag.Parse()
	if *configPath == "" {
		fmt.Fprintln(os.Stderr, "missing -config")
		os.Exit(2)
	}

	if err := xray.RunXray(*configPath); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	// The parent owns this process and stops it with the Windows process
	// handle.  Keep the process alive until that happens; Xray itself runs its
	// workers asynchronously after RunXray returns.
	select {}
}
