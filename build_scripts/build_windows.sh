#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"

# The desktop app bridge links against the libXray module. vendor/Xray-core is
# retained as a CLI/reference checkout and must not be patched or used as the
# app integration source.
if [[ ! -f "$DIR/libXray/go.mod" ]]; then
  echo "Missing libXray submodule. Run: git submodule update --init libXray" >&2
  exit 1
fi

cd "$DIR/go_core"

# The Windows bridge requires cgo. Prefer a user-provided compiler, then
# fall back to the common Chocolatey MinGW-w64 installation path.
export CGO_ENABLED=1

if [[ -z "${CC:-}" ]]; then
  if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
    CC="$(command -v x86_64-w64-mingw32-gcc)"
  elif [[ -x "/c/ProgramData/mingw64/mingw64/bin/x86_64-w64-mingw32-gcc.exe" ]]; then
    CC="/c/ProgramData/mingw64/mingw64/bin/x86_64-w64-mingw32-gcc.exe"
  else
    echo "Missing MinGW-w64 compiler x86_64-w64-mingw32-gcc." >&2
    echo "Install MinGW-w64 or set CC explicitly before running this script." >&2
    exit 1
  fi
fi

export CC

go mod download

GOOS=windows GOARCH=amd64 go build -buildmode=c-shared \
  -ldflags="-linkmode external -extldflags '-static'" \
  -o ../bindings/libgo_native_bridge.dll \
  .
