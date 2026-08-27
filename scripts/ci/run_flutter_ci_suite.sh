#!/usr/bin/env bash
set -euo pipefail

# Security scan
if ! command -v git-secrets >/dev/null 2>&1; then
  rm -rf /tmp/git-secrets
  git clone https://github.com/awslabs/git-secrets.git /tmp/git-secrets
  sudo make install -C /tmp/git-secrets
fi

git secrets --install
git secrets --scan

# XConnect-One v1 runtime policy
bash ./scripts/ci/check_xconnect_one_runtime.sh

# Shared overlay core and CLI verification
cli_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/xconnect-cli.XXXXXX")"
(
  cd go_core
  go test ./...
  go vet ./...
  go build -o "$cli_build_dir/xconnect" ./cmd/xconnect
)

# Flutter verification
flutter pub get
flutter analyze
flutter test
