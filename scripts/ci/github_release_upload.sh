#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${1:-release-artifacts}"
tag="${RELEASE_TAG:-daily-${GITHUB_RUN_NUMBER:-0}}"
title="${RELEASE_TITLE:-Daily Build ${GITHUB_RUN_NUMBER:-0}}"
notes="${RELEASE_NOTES:-Automated build}"

mapfile -d '' files < <(find "$artifact_dir" -type f -print0)

if [[ "${#files[@]}" -eq 0 ]]; then
  echo "No release artifacts found in $artifact_dir" >&2
  exit 1
fi

if gh release view "$tag" --repo "${GITHUB_REPOSITORY}" >/dev/null 2>&1; then
  echo "Release $tag exists. Updating release metadata and uploading artifacts..."
  gh release edit "$tag" --repo "${GITHUB_REPOSITORY}" --title "$title" --notes "$notes" || true
  gh release upload "$tag" "${files[@]}" --repo "${GITHUB_REPOSITORY}" --clobber
else
  echo "Creating release $tag with ${#files[@]} artifacts..."
  gh release create "$tag" "${files[@]}" --repo "${GITHUB_REPOSITORY}" --title "$title" --notes "$notes"
fi
