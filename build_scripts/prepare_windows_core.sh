#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${1:?usage: prepare_windows_core.sh output-dir}"
cd "$root/go_core"
core_dir="$(go list -m -f '{{.Dir}}' github.com/xtls/xray-core)"
mkdir -p "$output_dir/core"
cp -R "$core_dir/." "$output_dir/core/"
chmod -R u+w "$output_dir/core"
(
  cd "$output_dir/core"
  git apply --check "$root/build_scripts/patches/xray-core-windows-adapter-reuse.patch"
  git apply "$root/build_scripts/patches/xray-core-windows-adapter-reuse.patch"
)
# Use a temporary module file and isolated source copy. Neither the pinned
# go.mod nor the shared module cache is changed.
go run "$root/build_scripts/write_windows_core_modfile.go" "$root" "$output_dir"
