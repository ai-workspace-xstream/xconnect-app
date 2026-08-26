#!/usr/bin/env bash
set -euo pipefail

if command -v ldconfig >/dev/null 2>&1; then
  ldconfig
fi
