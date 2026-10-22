#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${GITHUB_OUTPUT:-}" ]]; then
  echo "GITHUB_OUTPUT is required" >&2
  exit 1
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pubspec_version="$(sed -n 's/^version:[[:space:]]*//p' "$project_root/pubspec.yaml" | head -n 1)"
if [[ ! "$pubspec_version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(\+([0-9]+))?$ ]]; then
  echo "Invalid pubspec version: ${pubspec_version:-<empty>}" >&2
  exit 1
fi
app_version="${BASH_REMATCH[1]}"
build_number="${BASH_REMATCH[3]:-0}"
msi_version="${app_version%.*}.${build_number}"
short_sha="${GITHUB_SHA:-unknown}"
short_sha="${short_sha:0:7}"
build_id="${GITHUB_RUN_ID:-${GITHUB_RUN_NUMBER:-0}}"
build_ref="${BUILD_REF_OVERRIDE:-${GITHUB_REF_NAME:-}}"

if [[ "${GITHUB_REF_TYPE:-}" == "tag" || "$build_ref" == v* ]]; then
  release_tag="$build_ref"
  release_version="${build_ref#v}"
  if [[ "$release_version" != "$msi_version" ]]; then
    echo "Release ref ${build_ref} does not match Windows MSI version ${msi_version}" >&2
    exit 1
  fi
  release_title="XConnect ${release_version}"
  release_notes="Automated stable release for ${GITHUB_REF_NAME}"
elif [[ "$build_ref" == "main" ]]; then
  release_tag="latest-${build_id}-${short_sha}"
  release_title="latest"
  release_notes="Latest main build ${build_id} from ${GITHUB_SHA:-unknown}"
elif [[ "$build_ref" == release/v* ]]; then
  release_branch_version="${build_ref#release/v}"
  if [[ "$release_branch_version" != "$msi_version" ]]; then
    echo "Release branch ${build_ref} does not match Windows MSI version ${msi_version}" >&2
    exit 1
  fi
  release_tag="release-${msi_version}-${build_id}-${short_sha}"
  release_title="XConnect ${msi_version}"
  release_notes="Production release-branch build ${build_id} from ${build_ref} (${GITHUB_SHA:-unknown})"
else
  release_tag="build-${build_id}-${short_sha}"
  release_title="$release_tag"
  release_notes="Feature build ${build_id} from ${build_ref:-unknown} (${GITHUB_SHA:-unknown})"
fi

if [[ -n "${RELEASE_TAG_OVERRIDE:-}" && "$build_ref" != v* && "$build_ref" != release/v* ]]; then
  release_tag="$RELEASE_TAG_OVERRIDE"
fi

release_notes="${release_notes}; app version ${app_version}+${build_number}, Windows MSI version ${msi_version}; commit ${GITHUB_SHA:-unknown}"

{
  echo "release_tag=${release_tag}"
  echo "release_title=${release_title}"
  echo "release_notes=${release_notes}"
} >> "$GITHUB_OUTPUT"
