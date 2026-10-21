#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$project_root/go_core"
export CGO_ENABLED=0
go mod download
windows_build_dir="$(mktemp -d)"
trap 'rm -rf "$windows_build_dir"' EXIT
bash "$project_root/build_scripts/prepare_windows_core.sh" "$windows_build_dir"
cp "$project_root/scripts/ci/adapter_reuse_windows_test.go" "$windows_build_dir/core/proxy/tun/adapter_reuse_windows_test.go"
go test -mod=readonly -modfile "$windows_build_dir/windows.mod" github.com/xtls/xray-core/proxy/tun -run '^TestXConnect'

go test -mod=readonly ./internal/corestatus
go vet -mod=readonly windows_core_process.go windows_core_process_test.go
go test -mod=readonly windows_core_process.go windows_core_process_test.go
# Build the exact independently launched Windows helper without creating a release.
go build -modfile "$windows_build_dir/windows.mod" -mod=readonly -buildvcs=false -o "${RUNNER_TEMP:?}/xconnect-core.exe" ./cmd/xconnect-core
