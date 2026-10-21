#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$project_root/go_core"
export CGO_ENABLED=0

go test -mod=readonly ./internal/corestatus
go vet -mod=readonly windows_core_process.go windows_core_process_test.go
go test -mod=readonly windows_core_process.go windows_core_process_test.go
# Build the exact independently launched Windows helper without creating a release.
go build -mod=readonly -buildvcs=false -o "${RUNNER_TEMP:?}/xconnect-core.exe" ./cmd/xconnect-core
