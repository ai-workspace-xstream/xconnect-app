#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$project_root"

locked_revision="$(git ls-tree HEAD libXray | awk '{print $3}')"
if [[ -z "$locked_revision" || ! -f libXray/go.mod ]]; then
  echo 'Initialize the pinned libXray submodule: git submodule update --init --recursive libXray' >&2
  exit 1
fi
actual_revision="$(git -C libXray rev-parse HEAD)"
if [[ "$actual_revision" != "$locked_revision" ]]; then
  echo 'libXray checkout does not match the application gitlink; refuse an unpinned build.' >&2
  exit 1
fi
if ! git -C libXray diff --quiet || ! git -C libXray diff --cached --quiet; then
  echo 'libXray has tracked local changes; build from a clean checkout without discarding them.' >&2
  exit 1
fi
if ! grep -Eq '^replace github.com/xtls/libxray => ../libXray$' go_core/go.mod; then
  echo 'The Go bridge must use the pinned libXray submodule.' >&2
  exit 1
fi
echo "libXray pinned revision: $locked_revision"
