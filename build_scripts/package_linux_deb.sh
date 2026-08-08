#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

VERSION="${VERSION:-$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)}"
ARCH="${ARCH:-amd64}"
DIST_DIR="$PROJECT_ROOT/dist/linux"
PACKAGE_ROOT="$DIST_DIR/package-root"
BUNDLE_DIR="$PROJECT_ROOT/build/linux/x64/release/bundle"
NFPM_VERSION="${NFPM_VERSION:-2.41.2}"
NFPM_BIN="$PROJECT_ROOT/.tools/nfpm"

mkdir -p "$DIST_DIR" "$PACKAGE_ROOT/opt/xconnect" \
  "$PACKAGE_ROOT/usr/share/applications" \
  "$PACKAGE_ROOT/usr/share/icons/hicolor/256x256/apps" \
  "$PACKAGE_ROOT/usr/libexec/xconnect" \
  "$PACKAGE_ROOT/usr/share/polkit-1/actions" \
  "$PROJECT_ROOT/.tools"

if [[ ! -x "$NFPM_BIN" ]]; then
  curl -fsSL "https://github.com/goreleaser/nfpm/releases/download/v${NFPM_VERSION}/nfpm_${NFPM_VERSION}_$(uname -s)_$(uname -m).tar.gz" \
    | tar -xz -C "$PROJECT_ROOT/.tools" nfpm
fi

BINARY_PATH="$BUNDLE_DIR/xconnect"
if [[ ! -f "$BINARY_PATH" && -f "$BUNDLE_DIR/xconnect-x64" ]]; then
  BINARY_PATH="$BUNDLE_DIR/xconnect-x64"
fi

cp -R "$BUNDLE_DIR/"* "$PACKAGE_ROOT/opt/xconnect/"
cp "$BINARY_PATH" "$PACKAGE_ROOT/opt/xconnect/xconnect"
cp packaging/linux/xconnect.desktop "$PACKAGE_ROOT/usr/share/applications/xconnect.desktop"
cp assets/logo.png "$PACKAGE_ROOT/usr/share/icons/hicolor/256x256/apps/xconnect.png"
cp scripts/linux/xconnect-net-helper "$PACKAGE_ROOT/usr/libexec/xconnect/xconnect-net-helper"
cp packaging/linux/org.xconnect.policy "$PACKAGE_ROOT/usr/share/polkit-1/actions/org.xconnect.policy"
chmod 0755 "$PACKAGE_ROOT/usr/libexec/xconnect/xconnect-net-helper"
chmod 0755 packaging/nfpm/postinstall.sh

VERSION="$VERSION" "$NFPM_BIN" package \
  --packager deb \
  --config packaging/nfpm/nfpm.yaml \
  --target "$DIST_DIR/xconnect_${VERSION}_${ARCH}.deb"

echo "Built $DIST_DIR/xconnect_${VERSION}_${ARCH}.deb"
