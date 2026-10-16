#!/usr/bin/env bash
set -euo pipefail

# Apply the project's lipo compatibility adapter to prepare, build and embed.
# Keep the Flutter SDK itself unchanged.
script_dir="$(cd "$(dirname "$0")" && pwd)"
export PATH="${script_dir}/apple-tools:${PATH}"
exec /bin/bash "${FLUTTER_ROOT}/packages/flutter_tools/bin/macos_assemble.sh" "$@"
