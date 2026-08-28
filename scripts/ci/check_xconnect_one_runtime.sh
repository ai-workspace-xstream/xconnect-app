#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

runtime_paths=(
  pubspec.yaml
  go_core/go.mod
  go_core/go.sum
  go_core/overlay
  go_core/cmd/xconnect
  lib
  android
  ios
  macos
  windows
  linux
)

existing_runtime_paths=()
for runtime_path in "${runtime_paths[@]}"; do
  if [[ -e "$runtime_path" ]]; then
    existing_runtime_paths+=("$runtime_path")
  fi
done

if rg --ignore-case --line-number --glob '!**/*_test.go' \
    --glob '!**/*_test.dart' 'sing[-_]?box' \
    "${existing_runtime_paths[@]}"; then
  echo "Unsupported proxy core reference found in a v1 runtime path." >&2
  exit 1
fi

rg --quiet 'github\.com/xtls/libxray' go_core/go.mod
rg --quiet "supportedCoreId = 'xray'" \
  lib/product/runtime/runtime_core_policy.dart
rg --quiet "supportedAdapterId = 'libXray'" \
  lib/product/runtime/runtime_core_policy.dart
test -f go_core/overlay/signedconfig/testdata/signed-config-ed25519-vector.json
rg --quiet 'ProxyCoreXray[[:space:]]*=[[:space:]]*"xray"' \
  go_core/overlay/signedconfig/contract.go
rg --quiet 'RelayTargetPort[[:space:]]*=[[:space:]]*51820' \
  go_core/overlay/signedconfig/contract.go
rg --quiet 'config-contract' go_core/cmd/xconnect/main.go
rg --quiet 'join-tokens/exchange' go_core/overlay/controlplane/enrollment.go
rg --quiet 'enrollment/signed-config' go_core/overlay/controlplane/enrollment.go
rg --quiet 'EnrollmentSecretPath' go_core/overlay/state/store.go
rg --quiet 'allow-insecure-localhost' go_core/cmd/xconnect/main.go

for artifact_root in build dist artifacts; do
  if [[ ! -d "$artifact_root" ]]; then
    continue
  fi
  if find "$artifact_root" -type f -iname '*sing*box*' -print -quit | \
      rg --quiet '.'; then
    echo "Unsupported proxy core artifact found under $artifact_root." >&2
    exit 1
  fi
done
