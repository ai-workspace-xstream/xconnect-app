#!/usr/bin/env bash
set -e

# 计算脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 基础路径全基于绝对路径
BUNDLE_DIR="$PROJECT_ROOT/build/linux/x64/release/bundle"
LIB_DIR="$BUNDLE_DIR/lib"
APPDIR="$PROJECT_ROOT/build/linux/AppDir"
APPIMAGE_DIR="$PROJECT_ROOT/build/linux/x64/release/AppImage"
OUTPUT_ZIP="$BUNDLE_DIR/xconnect-linux.zip"
OUTPUT_TAR="$BUNDLE_DIR/xconnect-linux-x64.tar.gz"
APPIMAGE_OUTPUT="$APPIMAGE_DIR/xconnect-linux.AppImage"
APPIMAGE_TMP_DIR="$PROJECT_ROOT/build/linux/appimage-tmp"

echo ">>> Preparing directories..."
mkdir -p "$LIB_DIR"
rm -rf "$APPDIR" "$APPIMAGE_TMP_DIR"
mkdir -p "$APPDIR/usr/bin"
mkdir -p "$APPDIR/usr/lib"
mkdir -p "$APPIMAGE_DIR"
mkdir -p "$APPIMAGE_TMP_DIR"

echo ">>> Searching and copying libgo_native_bridge.so ..."
FOUND=false

# 查找并复制
while IFS= read -r sofile; do
    # Flutter already places the Linux bridge in the bundle's lib directory.
    # Copying that file onto itself makes cp exit non-zero, which aborts the
    # packaging job under `set -e`.
    if [[ "$sofile" != "$LIB_DIR/libgo_native_bridge.so" ]]; then
        cp -u "$sofile" "$LIB_DIR/"
    fi
    FOUND=true
done < <(find "$PROJECT_ROOT" -name 'libgo_native_bridge.so')

if [[ "$FOUND" != "true" ]]; then
    echo "libgo_native_bridge.so not found; run build_scripts/build_linux.sh first." >&2
    exit 1
fi

echo ">>> Packaging portable archives (tar.gz + zip)..."
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/xconnect-linux-pkg-XXXXXX")"
rm -f "$OUTPUT_ZIP" "$OUTPUT_TAR"

tar -czf "$TMP_DIR/xconnect-linux-x64.tar.gz" -C "$BUNDLE_DIR" .
(
    cd "$BUNDLE_DIR"
    zip -r "$TMP_DIR/xconnect-linux.zip" .
)
mv "$TMP_DIR/xconnect-linux-x64.tar.gz" "$OUTPUT_TAR"
mv "$TMP_DIR/xconnect-linux.zip" "$OUTPUT_ZIP"
rm -rf "$TMP_DIR"

echo ">>> Preparing AppDir structure..."
cp -v "$BUNDLE_DIR/xconnect" "$APPDIR/usr/bin/"
cp -v "$LIB_DIR/"*.so "$APPDIR/usr/lib/"


echo ">>> Generating icon..."
mkdir -p "$APPDIR/usr/share/icons/hicolor/256x256/apps/"
convert "$PROJECT_ROOT/assets/logo.png" -resize 256x256 "$APPDIR/xconnect.png"
convert "$PROJECT_ROOT/assets/logo.png" -resize 256x256 "$APPDIR/usr/share/icons/hicolor/256x256/apps/xconnect.png"

echo ">>> Preparing AppDir structure/xconnect.desktop..."
cat << EOF > "$APPDIR/xconnect.desktop"
[Desktop Entry]
Type=Application
Name=XConnect
Comment=XConnect secure network desktop client
Exec=xconnect
Icon=xconnect
Categories=Network;Utility;
StartupWMClass=xconnect
StartupNotify=true
EOF

# 生成 AppRun 启动器
cat << 'EOF' > "$APPDIR/AppRun"
#!/bin/bash
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/lib:$LD_LIBRARY_PATH"
exec "$HERE/usr/bin/xconnect" "$@"
EOF

chmod +x "$APPDIR/AppRun"

echo ">>> Downloading linuxdeploy and appimagetool if not exist..."
export PATH="$HOME/.local/bin:$PATH"
mkdir -p "$HOME/.local/bin"

if [ ! -f "$HOME/.local/bin/linuxdeploy-x86_64.AppImage" ]; then
    wget -O "$HOME/.local/bin/linuxdeploy-x86_64.AppImage" https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
    chmod +x "$HOME/.local/bin/linuxdeploy-x86_64.AppImage"
fi

if [ ! -f "$HOME/.local/bin/appimagetool-x86_64.AppImage" ]; then
    wget -O "$HOME/.local/bin/appimagetool-x86_64.AppImage" \
        https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage
    chmod +x "$HOME/.local/bin/appimagetool-x86_64.AppImage"
fi

echo ">>> Building AppImage..."
export APPIMAGE_EXTRACT_AND_RUN=1
(
    cd "$APPIMAGE_TMP_DIR"
    "$HOME/.local/bin/linuxdeploy-x86_64.AppImage" --appdir "$APPDIR" --output appimage
)

GENERATED_APPIMAGE="$(find "$APPIMAGE_TMP_DIR" -maxdepth 1 -type f -name '*.AppImage' | head -n 1 || true)"
if [[ -z "$GENERATED_APPIMAGE" ]]; then
    echo "AppImage build completed but no .AppImage output was found." >&2
    exit 1
fi

rm -f "$APPIMAGE_OUTPUT"
mv "$GENERATED_APPIMAGE" "$APPIMAGE_OUTPUT"
rm -rf "$APPIMAGE_TMP_DIR"
echo ">>> AppImage build complete: $APPIMAGE_OUTPUT"
