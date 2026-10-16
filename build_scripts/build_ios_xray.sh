#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Xcode does not load the user's shell startup files, so the Go installation
# used by the terminal may not be present in PATH. Probe it and common
# installation locations explicitly.
GO_BIN=""
if command -v go >/dev/null 2>&1; then
  GO_BIN="$(command -v go)"
fi

if [[ -z "${GO_BIN}" && -n "${GOROOT:-}" && -x "${GOROOT}/bin/go" ]]; then
  GO_BIN="${GOROOT}/bin/go"
fi

for candidate in \
  "${HOME:-}/.local/devtools/go/bin/go" \
  "/opt/homebrew/bin/go" \
  "/usr/local/bin/go"; do
  if [[ -z "${GO_BIN}" && -x "${candidate}" ]]; then
    GO_BIN="${candidate}"
  fi
done

if [[ -z "${GO_BIN}" ]]; then
  echo "go command not found. Install Go or expose it through PATH/GOROOT."
  exit 1
fi

echo ">>> Using Go: $GO_BIN"

TARGET_PLATFORM="${PLATFORM_NAME:-iphoneos}"
case "$TARGET_PLATFORM" in
  iphoneos) DEFAULT_ARCHS=arm64 ;;
  iphonesimulator) DEFAULT_ARCHS="$(uname -m)" ;;
  *) echo "Unsupported iOS platform: $TARGET_PLATFORM" >&2; exit 1 ;;
esac
OUTPUT_DIR="$DIR/build/ios/$TARGET_PLATFORM"
LIBXRAY_DIR="$DIR/libXray"
OUTPUT_ARCHIVE="$OUTPUT_DIR/libxray.a"
OUTPUT_HEADER="$OUTPUT_DIR/libxray.h"

if [[ ! -d "$LIBXRAY_DIR" || ! -f "$LIBXRAY_DIR/go.mod" ]]; then
  echo "libXray submodule is missing. Run:"
  echo "  git submodule update --init --recursive libXray"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_ARCHIVE" "$OUTPUT_HEADER"

cd "$DIR/go_core"

echo ">>> Building iOS Packet Tunnel bridge archive..."

export CGO_ENABLED=1
export GOOS=ios
export CC="$(xcrun --sdk "$TARGET_PLATFORM" --find clang)"
SDK_PATH="$(xcrun --sdk "$TARGET_PLATFORM" --show-sdk-path)"
MIN_VERSION="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"

"$GO_BIN" mod download
SLICE_ARCHIVES=()
for slice_arch in ${ARCHS:-$DEFAULT_ARCHS}; do
  case "$slice_arch" in
    arm64) export GOARCH=arm64 ;;
    x86_64) export GOARCH=amd64 ;;
    *) echo "Unsupported iOS architecture: $slice_arch" >&2; exit 1 ;;
  esac
  TARGET_TRIPLE="$slice_arch-apple-ios$MIN_VERSION"
  if [[ "$TARGET_PLATFORM" == iphonesimulator ]]; then
    TARGET_TRIPLE="$TARGET_TRIPLE-simulator"
  fi
  export CGO_CFLAGS="-target $TARGET_TRIPLE -isysroot $SDK_PATH"
  export CGO_LDFLAGS="$CGO_CFLAGS"
  SLICE_ARCHIVE="$OUTPUT_DIR/libxray-$slice_arch.a"
  "$GO_BIN" build -buildmode=c-archive -o "$SLICE_ARCHIVE" .
  SLICE_ARCHIVES+=("$SLICE_ARCHIVE")
  cp "$OUTPUT_DIR/libxray-$slice_arch.h" "$OUTPUT_HEADER"
done
xcrun lipo -create "${SLICE_ARCHIVES[@]}" -output "$OUTPUT_ARCHIVE"

echo ">>> Output archive: $OUTPUT_ARCHIVE"
echo ">>> Output header: $OUTPUT_HEADER"
