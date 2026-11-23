#!/usr/bin/env bash
set -euo pipefail

tag="${RELEASE_TAG:-daily-${GITHUB_RUN_NUMBER:-0}}"
release_json="/tmp/xconnect-release-assets.json"

if ! gh release view "$tag" --repo "${GITHUB_REPOSITORY}" --json assets > "$release_json" 2>/dev/null; then
  echo "::warning::Release $tag not found; skipping README download link update."
  exit 0
fi

python3 scripts/update_readme_downloads.py \
  --repo "${GITHUB_REPOSITORY}" \
  --tag "$tag" \
  --release-json "$release_json" \
  --readme README.md

if git diff --quiet -- README.md; then
  echo "README already up to date"
  exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add README.md
git commit -m "docs: refresh README download links [skip ci]"

# Attempt direct push (succeeds if branch is unprotected or token is allowed)
if git push origin HEAD:main 2>/dev/null; then
  echo "Successfully pushed README updates to main."
  exit 0
fi

echo "Direct push to main was declined (branch protection enabled). Creating or updating pull request..."
branch="automation/update-readme-${tag}"
if git push -f origin "HEAD:refs/heads/${branch}" 2>/dev/null; then
  echo "Branch ${branch} pushed. Creating or updating pull request..."
  gh pr create \
    --repo "${GITHUB_REPOSITORY}" \
    --title "docs: refresh README download links for ${tag}" \
    --body "Automated README update following release ${tag}." \
    --head "${branch}" \
    --base main || echo "Pull request creation skipped or already exists."
else
  echo "::warning::Could not push branch ${branch}; skipping automated README push."
fi

exit 0
