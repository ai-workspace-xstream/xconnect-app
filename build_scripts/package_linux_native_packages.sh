#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BUNDLE_DIR="$PROJECT_ROOT/build/linux/x64/release/bundle"
OUTPUT_DIR="$PROJECT_ROOT/build/linux/x64/release/packages"
STAGE_DIR="$OUTPUT_DIR/pkgroot"
NFPM_CONFIG="$OUTPUT_DIR/nfpm.yaml"

if [[ ! -d "$BUNDLE_DIR" ]]; then
  echo "Linux bundle directory not found: $BUNDLE_DIR" >&2
  exit 1
fi

if [[ ! -f "$BUNDLE_DIR/xconnect" ]]; then
  echo "Linux bundle executable not found: $BUNDLE_DIR/xconnect" >&2
  exit 1
fi

if ! command -v nfpm >/dev/null 2>&1; then
  echo "nfpm is required to build .deb/.rpm packages." >&2
  exit 1
fi

PUBSPEC_VERSION="$(sed -n 's/^version:[[:space:]]*//p' "$PROJECT_ROOT/pubspec.yaml" | head -n 1)"
APP_VERSION="${PUBSPEC_VERSION%%+*}"
RELEASE_NUMBER="1"
if [[ "$PUBSPEC_VERSION" == *"+"* ]]; then
  RELEASE_NUMBER="${PUBSPEC_VERSION#*+}"
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$STAGE_DIR/opt/xconnect"
mkdir -p "$STAGE_DIR/usr/bin"
mkdir -p "$STAGE_DIR/usr/share/applications"
mkdir -p "$STAGE_DIR/usr/share/icons/hicolor/256x256/apps"
mkdir -p "$STAGE_DIR/usr/libexec/xconnect"
mkdir -p "$STAGE_DIR/usr/share/polkit-1/actions"
mkdir -p "$STAGE_DIR/etc/ld.so.conf.d"

echo ">>> Staging Linux bundle for native packages ..."
rsync -a --delete "$BUNDLE_DIR/" "$STAGE_DIR/opt/xconnect/"

cat > "$STAGE_DIR/usr/bin/xconnect" <<'EOF'
#!/usr/bin/env bash
export LD_LIBRARY_PATH="/opt/xconnect/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec /opt/xconnect/xconnect "$@"
EOF
chmod +x "$STAGE_DIR/usr/bin/xconnect"

cat > "$STAGE_DIR/usr/share/applications/xconnect.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=XConnect
Comment=Secure Tunnel desktop client
Exec=/usr/bin/xconnect
Icon=xconnect
Terminal=false
Categories=Utility;Network;
EOF

cp "$PROJECT_ROOT/assets/logo.png" \
  "$STAGE_DIR/usr/share/icons/hicolor/256x256/apps/xconnect.png"
cp "$PROJECT_ROOT/scripts/linux/xconnect-net-helper" \
  "$STAGE_DIR/usr/libexec/xconnect/xconnect-net-helper"
cp "$PROJECT_ROOT/packaging/linux/org.xconnect.policy" \
  "$STAGE_DIR/usr/share/polkit-1/actions/org.xconnect.policy"
chmod 0755 "$STAGE_DIR/usr/libexec/xconnect/xconnect-net-helper"
printf '%s\n' '/opt/xconnect/lib' > "$STAGE_DIR/etc/ld.so.conf.d/xconnect.conf"

cat > "$NFPM_CONFIG" <<EOF
name: xconnect
arch: amd64
platform: linux
version: ${APP_VERSION}
release: ${RELEASE_NUMBER}
section: default
priority: optional
maintainer: XConnect Team
description: |
  XConnect desktop client for managing Secure Tunnel connections.
vendor: XConnect Team
homepage: https://github.com/cloud-neutral-toolkit/xconnect.svc.plus
license: Apache-2.0
depends:
  - libgtk-3-0
  - libayatana-appindicator3-1
  - libnotify-bin
  - "pkexec | policykit-1"
  - iproute2
  - libcap2-bin
  - libx11-6
  - libstdc++6
  - libsqlite3-0
overrides:
  rpm:
    depends:
      - libappindicator-gtk3
      - libnotify
      - polkit
      - iproute
      - libcap
      - libX11
      - libstdc++
      - sqlite-libs
contents:
  - src: ${STAGE_DIR}/opt/xconnect/
    dst: /opt/xconnect
  - src: ${STAGE_DIR}/usr/bin/xconnect
    dst: /usr/bin/xconnect
    file_info:
      mode: 0755
  - src: ${STAGE_DIR}/usr/share/applications/xconnect.desktop
    dst: /usr/share/applications/xconnect.desktop
  - src: ${STAGE_DIR}/usr/share/icons/hicolor/256x256/apps/xconnect.png
    dst: /usr/share/icons/hicolor/256x256/apps/xconnect.png
  - src: ${STAGE_DIR}/usr/libexec/xconnect/xconnect-net-helper
    dst: /usr/libexec/xconnect/xconnect-net-helper
    file_info:
      mode: 0755
  - src: ${STAGE_DIR}/usr/share/polkit-1/actions/org.xconnect.policy
    dst: /usr/share/polkit-1/actions/org.xconnect.policy
  - src: ${STAGE_DIR}/etc/ld.so.conf.d/xconnect.conf
    dst: /etc/ld.so.conf.d/xconnect.conf
scripts:
  postinstall: ${PROJECT_ROOT}/packaging/nfpm/postinstall.sh
  postremove: ${PROJECT_ROOT}/packaging/nfpm/postremove.sh
EOF

echo ">>> Building .deb package ..."
nfpm pkg \
  --packager deb \
  --config "$NFPM_CONFIG" \
  --target "$OUTPUT_DIR/xconnect-linux-amd64.deb"

echo ">>> Building .rpm package ..."
nfpm pkg \
  --packager rpm \
  --config "$NFPM_CONFIG" \
  --target "$OUTPUT_DIR/xconnect-linux-x86_64.rpm"

echo ">>> Linux native packages ready:"
echo "    $OUTPUT_DIR/xconnect-linux-amd64.deb"
echo "    $OUTPUT_DIR/xconnect-linux-x86_64.rpm"
