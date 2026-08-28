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
test -f go_core/overlay/credential/model.go
test -f go_core/overlay/credential/file_store.go
test -f go_core/overlay/credential/keychain_store_darwin.go
test -f go_core/overlay/credential/windows_store.go
rg --quiet 'device/session' go_core/overlay/controlplane/device.go
rg --quiet 'device/credential/rotate' go_core/overlay/controlplane/device.go
rg --quiet 'device/revoke' go_core/overlay/controlplane/device.go
rg --quiet '00bdb1b7a7203fa88c9bd01bc87ef416cafd04d3379934ad535dda1252f0ea80' \
  go_core/overlay/credential/model_test.go
rg --quiet 'case "sync"' go_core/cmd/xconnect/main.go
rg --quiet 'credential rotate' go_core/cmd/xconnect/main.go
rg --quiet 'allow-insecure-localhost' go_core/cmd/xconnect/main.go
test -f go_core/overlay/invite/testdata/invite-url-cases.json
rg --quiet 'overlay/invite' go_core/cmd/xconnect/main.go
test -f go_core/overlay/policy/testdata/policy-enforcement-artifact.json
rg --quiet '58941760a9ab4568d2e72a6f34a2cede891d8e678346da8e886d86263e5b780c' \
  go_core/overlay/policy/consumer_test.go
rg --quiet 'case "up"' go_core/cmd/xconnect/main.go
rg --quiet 'case "down"' go_core/cmd/xconnect/main.go
rg --quiet 'case "leave"' go_core/cmd/xconnect/main.go
rg --quiet 'admin invite create' go_core/cmd/xconnect/main.go
rg --quiet 'policy explain' go_core/cmd/xconnect/main.go
rg --quiet 'macos_packet_tunnel_host_required' go_core/cmd/xconnect/main.go
rg --quiet 'windows_service_host_required' go_core/cmd/xconnect/main.go
rg --quiet 'mobile_join_bridge_unavailable' \
  android/app/src/main/kotlin/plus/svc/xconnect/MainActivity.kt \
  ios/Runner/AppDelegate.swift macos/Runner/AppDelegate.swift
rg --quiet 'protected_device_session_unavailable' \
  android/app/src/main/kotlin/plus/svc/xconnect/MainActivity.kt \
  ios/Runner/AppDelegate.swift macos/Runner/AppDelegate.swift
if rg --line-number 'SharedPreferences|/api/overlay/v1|enrollment_token|wireguard_private_key' \
    lib/product/xconnect_one; then
  echo "Secret persistence or control-plane protocol leaked into Flutter product code." >&2
  exit 1
fi

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
