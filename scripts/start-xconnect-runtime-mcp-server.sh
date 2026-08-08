#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${XCONNECT_RUNTIME_APP_PATH:-/Applications/xconnect.app}"
RUNTIME_MCP="$APP_PATH/Contents/Resources/runtime-tools/xconnect-mcp/start-xconnect-mcp-server.sh"

if [ ! -x "$RUNTIME_MCP" ]; then
  echo "runtime mcp launcher not found: $RUNTIME_MCP" >&2
  echo "build and install app first (make macos-arm64/macos-intel)." >&2
  exit 1
fi

exec "$RUNTIME_MCP"
