//go:build ignore

// Prepare native paths for the isolated Windows dependency build on all hosts.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

func main() {
	if len(os.Args) != 3 {
		panic("expected repository and build directory")
	}
	root, err := filepath.Abs(os.Args[1])
	if err != nil {
		panic(err)
	}
	output, err := filepath.Abs(os.Args[2])
	if err != nil {
		panic(err)
	}
	for _, extension := range []string{"mod", "sum"} {
		data, err := os.ReadFile(filepath.Join(root, "go_core", "go."+extension))
		if err != nil {
			panic(err)
		}
		if err := os.WriteFile(filepath.Join(output, "windows."+extension), data, 0600); err != nil {
			panic(err)
		}
	}
	cmd := exec.Command("go", "mod", "edit", "-modfile", filepath.Join(output, "windows.mod"),
		"-replace", "github.com/xtls/libxray="+filepath.Join(root, "libXray"),
		"-replace", "github.com/xtls/xray-core="+filepath.Join(output, "core"))
	if result, err := cmd.CombinedOutput(); err != nil {
		panic(fmt.Sprintf("prepare Windows module: %v: %s", err, result))
	}
}
