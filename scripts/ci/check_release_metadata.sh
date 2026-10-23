#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
metadata_script="$project_root/scripts/ci/compute_release_metadata.sh"
# Version assertions must follow pubspec when a test build number increases.
# This changes the test inputs only, not the release naming policy.
pubspec_version="$(sed -n 's/^version:[[:space:]]*//p' "$project_root/pubspec.yaml" | head -n 1)"
app_version="${pubspec_version%%+*}"
build_number="${pubspec_version#*+}"
expected_msi_version="${app_version%.*}.${build_number}"
mismatched_msi_version="${app_version%.*}.$((build_number + 1))"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

run_case() {
  local expected_tag="$1"
  local expected_title="$2"
  shift 2
  local output_file="$test_dir/output"
  : > "$output_file"
  GITHUB_OUTPUT="$output_file" "$@" bash "$metadata_script"
  grep -Fx "release_tag=$expected_tag" "$output_file"
  grep -Fx "release_title=$expected_title" "$output_file"
  grep -F "Windows MSI version ${expected_msi_version};" "$output_file"
}

run_case "latest-310-abcdef1" "latest" \
  env GITHUB_EVENT_NAME=push GITHUB_REF_NAME=main GITHUB_RUN_ID=310 GITHUB_RUN_NUMBER=310 GITHUB_SHA=abcdef1234567890
run_case "v${expected_msi_version}" "XConnect ${expected_msi_version}" \
  env GITHUB_REF_TYPE=tag GITHUB_REF_NAME="v${expected_msi_version}" GITHUB_RUN_ID=311 GITHUB_SHA=abcdef1234567890
run_case "release-${expected_msi_version}-312-abcdef1" "XConnect ${expected_msi_version}" \
  env GITHUB_EVENT_NAME=push GITHUB_REF_NAME="release/v${expected_msi_version}" GITHUB_RUN_ID=312 GITHUB_SHA=abcdef1234567890
run_case "build-313-abcdef1" "build-313-abcdef1" \
  env GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_NAME=feature/test GITHUB_RUN_ID=313 GITHUB_SHA=abcdef1234567890

if GITHUB_OUTPUT="$test_dir/mismatch" GITHUB_REF_TYPE=tag GITHUB_REF_NAME="v${mismatched_msi_version}" GITHUB_SHA=abcdef1234567890 bash "$metadata_script" 2>/dev/null; then
  echo "Mismatched production version was accepted" >&2
  exit 1
fi

echo "Release metadata checks passed."
