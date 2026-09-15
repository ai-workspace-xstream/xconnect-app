#!/usr/bin/env bash
set -euo pipefail

# Store the local Google Play upload keystore in Vault KV v2.
# Optional overrides: VAULT_ADDR, ANDROID_KEYSTORE_PATH, ANDROID_KEY_ALIAS.
# The Vault CLI must already be authenticated.

readonly vault_mount="kv"
readonly vault_path="github-actions/xconnect-android-play-signing"
readonly default_keystore="$HOME/secure/xconnect-upload.jks"
export VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"

command -v vault >/dev/null 2>&1 || {
  echo "vault CLI is required" >&2
  exit 1
}

keystore_path="${ANDROID_KEYSTORE_PATH:-$default_keystore}"
if [[ ! -f "$keystore_path" ]]; then
  echo "Keystore not found: $keystore_path" >&2
  echo "Set ANDROID_KEYSTORE_PATH to the .jks file location." >&2
  exit 1
fi

if ! vault token lookup >/dev/null 2>&1; then
  echo "Vault CLI is not authenticated. Run vault login first." >&2
  exit 1
fi

key_alias="${ANDROID_KEY_ALIAS:-xconnect-upload}"
if [[ -z "${ANDROID_KEYSTORE_PASSWORD:-}" ]]; then
  read -r -s -p "Keystore password: " ANDROID_KEYSTORE_PASSWORD
  echo
fi
if [[ -z "${ANDROID_KEY_PASSWORD:-}" ]]; then
  read -r -s -p "Key password: " ANDROID_KEY_PASSWORD
  echo
fi

keystore_base64="$(base64 < "$keystore_path" | tr -d '\n')"

vault kv put -mount="$vault_mount" "$vault_path" \
  ANDROID_KEYSTORE_BASE64="$keystore_base64" \
  ANDROID_KEYSTORE_PASSWORD="$ANDROID_KEYSTORE_PASSWORD" \
  ANDROID_KEY_ALIAS="$key_alias" \
  ANDROID_KEY_PASSWORD="$ANDROID_KEY_PASSWORD"

unset keystore_base64 ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_PASSWORD key_alias
echo "Stored Android Play signing contract at ${vault_mount}/${vault_path}."
