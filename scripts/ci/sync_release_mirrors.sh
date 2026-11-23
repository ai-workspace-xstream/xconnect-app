#!/usr/bin/env bash
set -euo pipefail

artifacts_dir="${1:-release-artifacts}"
staging_dir="${STAGING_DIR:-matrix-output}"
product="${PRODUCT:-xconnect}"
repo="${GITHUB_REPOSITORY:-ai-workspace-xstream/xconnect-app}"
tag="${RELEASE_TAG:?RELEASE_TAG is required}"
app_version="${APP_VERSION:?APP_VERSION is required}"
build_number="${BUILD_NUMBER:-0}"
msi_version="${MSI_VERSION:-$app_version}"
channel="${RELEASE_CHANNEL:-latest}"
commit_sha="${COMMIT_SHA:-}"
workflow_run_url="${WORKFLOW_RUN_URL:-}"
require_mirror_sync="${REQUIRE_MIRROR_SYNC:-false}"

cn_enabled="false"
global_enabled="false"
if [[ -n "${OSS_ACCESS_KEY_ID:-}" && -n "${OSS_ACCESS_KEY_SECRET:-}" && -n "${OSS_BUCKET:-}" && -n "${OSS_ENDPOINT:-}" ]]; then
  cn_enabled="true"
fi
if [[ -n "${R2_ACCESS_KEY_ID:-}" && -n "${R2_SECRET_ACCESS_KEY:-}" && -n "${R2_BUCKET:-}" && -n "${R2_ENDPOINT:-}" ]]; then
  global_enabled="true"
fi

if [[ "$require_mirror_sync" == "true" && ( "$cn_enabled" != "true" || "$global_enabled" != "true" ) ]]; then
  echo "REQUIRE_MIRROR_SYNC=true but OSS or R2 credentials are incomplete." >&2
  exit 1
fi

existing_matrix="/tmp/${product}-existing-release-matrix.json"
rm -f "$existing_matrix"
for candidate in \
  "https://dl.svc.plus/releases/${product}/release-matrix.json" \
  "https://cn-dl.svc.plus/releases/${product}/release-matrix.json"; do
  if curl -fsSL --max-time 10 "$candidate" -o "$existing_matrix" 2>/dev/null; then
    break
  fi
  rm -f "$existing_matrix"
done

rm -rf "$staging_dir"
python3 scripts/ci/build_release_matrix.py \
  --artifacts-dir "$artifacts_dir" \
  --output-dir "$staging_dir" \
  --repo "$repo" \
  --product "$product" \
  --tag "$tag" \
  --version "$app_version" \
  --build-number "$build_number" \
  --msi-version "$msi_version" \
  --channel "$channel" \
  --commit-sha "$commit_sha" \
  --workflow-run-url "$workflow_run_url" \
  --existing-matrix "${existing_matrix}" \
  --cn-synced "$cn_enabled" \
  --global-synced "$global_enabled"

tag_root="${staging_dir}/releases/${product}/${tag}"
rel_root="releases/${product}"

install_ossutil() {
  if command -v ossutil >/dev/null 2>&1; then
    return 0
  fi
  curl -fsSL "https://gosspublic.alicdn.com/ossutil/1.7.19/ossutil-v1.7.19-linux-amd64.zip" -o /tmp/ossutil.zip
  unzip -oq /tmp/ossutil.zip -d /tmp/ossutil-bin
  chmod +x /tmp/ossutil-bin/ossutil-v1.7.19-linux-amd64/ossutil
  export PATH="/tmp/ossutil-bin/ossutil-v1.7.19-linux-amd64:${PATH}"
}

sync_aliyun_oss() {
  install_ossutil
  local cfg="/tmp/.ossutilconfig"
  trap 'rm -f /tmp/.ossutilconfig' RETURN
  cat > "$cfg" <<EOF
[Credentials]
language=EN
endpoint=${OSS_ENDPOINT}
accessKeyID=${OSS_ACCESS_KEY_ID}
accessKeySecret=${OSS_ACCESS_KEY_SECRET}
EOF
  chmod 600 "$cfg"

  # 1. Upload immutable tag directory
  ossutil -c "$cfg" cp -rf \
    --meta "Cache-Control:public, max-age=31536000, immutable" \
    "${tag_root}/" "oss://${OSS_BUCKET}/${rel_root}/${tag}/"

  # 2. Verify sample object via HEAD before switching pointers
  ossutil -c "$cfg" stat "oss://${OSS_BUCKET}/${rel_root}/${tag}/matrix.json" >/dev/null

  # 3. Upload channel & aggregated release-matrix.json with short TTL
  if [[ -d "${staging_dir}/${rel_root}/channels" ]]; then
    ossutil -c "$cfg" cp -rf \
      --meta "Cache-Control:public, max-age=60, must-revalidate" \
      "${staging_dir}/${rel_root}/channels/" "oss://${OSS_BUCKET}/${rel_root}/channels/"
  fi
  ossutil -c "$cfg" cp -f \
    --meta "Cache-Control:public, max-age=60, must-revalidate" \
    "${staging_dir}/${rel_root}/release-matrix.json" \
    "oss://${OSS_BUCKET}/${rel_root}/release-matrix.json"

  # 4. Optional Aliyun CDN cache refresh if aliyun CLI is available
  if command -v aliyun >/dev/null 2>&1 && [[ -n "${OSS_CDN_DOMAIN:-}" ]]; then
    aliyun cdn RefreshObjectCaches \
      --ObjectPath "https://${OSS_CDN_DOMAIN}/${rel_root}/release-matrix.json"$'\n'"https://${OSS_CDN_DOMAIN}/${rel_root}/channels/${channel}.json" \
      --ObjectType File >/dev/null || echo "::warning::Aliyun CDN cache refresh skipped or failed"
  fi
}

sync_cloudflare_r2() {
  AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}" \
  AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}" \
  AWS_DEFAULT_REGION="auto" \
  aws s3 cp "${tag_root}/" "s3://${R2_BUCKET}/${rel_root}/${tag}/" \
    --recursive \
    --endpoint-url "${R2_ENDPOINT}" \
    --cache-control "public, max-age=31536000, immutable"

  AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}" \
  AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}" \
  AWS_DEFAULT_REGION="auto" \
  aws s3api head-object \
    --bucket "${R2_BUCKET}" \
    --key "${rel_root}/${tag}/matrix.json" \
    --endpoint-url "${R2_ENDPOINT}" >/dev/null

  if [[ -d "${staging_dir}/${rel_root}/channels" ]]; then
    AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}" \
    AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}" \
    AWS_DEFAULT_REGION="auto" \
    aws s3 cp "${staging_dir}/${rel_root}/channels/" "s3://${R2_BUCKET}/${rel_root}/channels/" \
      --recursive \
      --endpoint-url "${R2_ENDPOINT}" \
      --cache-control "public, max-age=60, must-revalidate"
  fi

  AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}" \
  AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}" \
  AWS_DEFAULT_REGION="auto" \
  aws s3 cp "${staging_dir}/${rel_root}/release-matrix.json" \
    "s3://${R2_BUCKET}/${rel_root}/release-matrix.json" \
    --endpoint-url "${R2_ENDPOINT}" \
    --cache-control "public, max-age=60, must-revalidate"
}

if [[ "$cn_enabled" == "true" ]]; then
  sync_aliyun_oss
  curl -fsSI "https://${OSS_CDN_DOMAIN:-cn-dl.svc.plus}/${rel_root}/release-matrix.json" >/dev/null
else
  echo "::warning title=CN OSS Mirror::Aliyun OSS credentials unavailable; skipped cn-dl.svc.plus mirror sync."
fi

if [[ "$global_enabled" == "true" ]]; then
  sync_cloudflare_r2
  curl -fsSI "https://dl.svc.plus/${rel_root}/release-matrix.json" >/dev/null
else
  echo "::warning title=Global R2 Mirror::Cloudflare R2 credentials unavailable; skipped dl.svc.plus mirror sync."
fi
