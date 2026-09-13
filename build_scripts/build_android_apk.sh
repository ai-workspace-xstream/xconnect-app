#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APK_PATH="$ROOT_DIR/build/app/outputs/flutter-apk/app-release.apk"
AAB_PATH="$ROOT_DIR/build/app/outputs/bundle/release/app-release.aab"
KEY_PROPERTIES="$ROOT_DIR/android/key.properties"
KEYSTORE_PATH="$ROOT_DIR/android/upload-keystore.jks"
REQUIRE_SIGNING="${1:-${REQUIRE_ANDROID_SIGNING:-false}}"
BRANCH="${BRANCH:-$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)}"
BUILD_ID="${BUILD_ID:-$(git -C "$ROOT_DIR" rev-parse --short HEAD)}"
BUILD_DATE="${BUILD_DATE:-$(date '+%Y-%m-%d')}"
UNAME_S="${UNAME_S:-$(uname -s)}"
FLUTTER_BIN="${FLUTTER:-flutter}"

normalize_exec_path() {
  local value="$1"
  if [[ -z "$value" || "$value" == "flutter" ]]; then
    printf '%s' "$value"
    return 0
  fi

  if command -v cygpath >/dev/null 2>&1 && [[ "$value" =~ ^[A-Za-z]:[\\/].* ]]; then
    cygpath -u "$value"
    return 0
  fi

  printf '%s' "$value"
}

FLUTTER_BIN="$(normalize_exec_path "$FLUTTER_BIN")"

case "$UNAME_S" in
  Darwin|Linux|MINGW*|MSYS*|CYGWIN*|Windows_NT)
    ;;
  *)
    echo "Android APK build is only supported on macOS, Linux, or Windows"
    exit 0
    ;;
esac

if [[ -n "$FLUTTER_BIN" ]] && [[ "$FLUTTER_BIN" != "flutter" ]] && [[ ! -e "$FLUTTER_BIN" ]]; then
  echo "Flutter executable not found: $FLUTTER_BIN"
  exit 0
fi

cd "$ROOT_DIR"

cleanup_signing_files() {
  rm -f "$KEY_PROPERTIES" "$KEYSTORE_PATH"
}
trap cleanup_signing_files EXIT

if [[ -n "${ANDROID_KEYSTORE_BASE64:-}" && -n "${ANDROID_KEYSTORE_PASSWORD:-}" && -n "${ANDROID_KEY_ALIAS:-}" && -n "${ANDROID_KEY_PASSWORD:-}" ]]; then
  printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 --decode > "$KEYSTORE_PATH"
  cat > "$KEY_PROPERTIES" <<EOF
storePassword=$ANDROID_KEYSTORE_PASSWORD
keyPassword=$ANDROID_KEY_PASSWORD
keyAlias=$ANDROID_KEY_ALIAS
storeFile=$KEYSTORE_PATH
EOF
elif [[ "$REQUIRE_SIGNING" == "true" ]]; then
  echo "Android release signing is required, but the keystore contract is incomplete." >&2
  echo "Set ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, and ANDROID_KEY_PASSWORD." >&2
  exit 1
else
  echo ">>> Android signing secrets unavailable; using debug signing for verification builds."
fi

echo ">>> Building Android native bridge (.so) ..."
./build_scripts/build_android_xray.sh

echo ">>> Building Android release APK and App Bundle ..."
"$FLUTTER_BIN" build apk --release \
  --dart-define=BRANCH_NAME="$BRANCH" \
  --dart-define=BUILD_ID="$BUILD_ID" \
  --dart-define=BUILD_DATE="$BUILD_DATE"

"$FLUTTER_BIN" build appbundle --release \
  --dart-define=BRANCH_NAME="$BRANCH" \
  --dart-define=BUILD_ID="$BUILD_ID" \
  --dart-define=BUILD_DATE="$BUILD_DATE"

if [[ ! -f "$APK_PATH" ]]; then
  echo "APK build completed but output not found: $APK_PATH"
  exit 1
fi

if [[ ! -f "$AAB_PATH" ]]; then
  echo "App Bundle build completed but output not found: $AAB_PATH"
  exit 1
fi

echo ">>> Android artifacts ready:"
echo "    $APK_PATH"
echo "    $AAB_PATH"
