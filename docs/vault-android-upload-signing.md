# Vault contract for Android upload signing

Store the Android upload key in the existing Vault KV v2 mount at
`kv/data/github-actions/xconnect-android-play-signing`. The GitHub Actions role
`github-actions-xconnect-app` reads this path through JWT/OIDC and should have
read access to this path only.

| Vault field | Temporary build value | Meaning |
| --- | --- | --- |
| `ANDROID_KEYSTORE_BASE64` | `android/upload-keystore.jks` | Base64 encoded keystore bytes |
| `ANDROID_KEYSTORE_PASSWORD` | `storePassword` | Keystore password |
| `ANDROID_KEY_ALIAS` | `keyAlias` | Upload key alias |
| `ANDROID_KEY_PASSWORD` | `keyPassword` | Upload key password |

`storeFile` is intentionally not stored in Vault. CI writes the runner-local
absolute path into a temporary `android/key.properties`, builds the APK/AAB,
and removes generated files on exit. The local `android/key.properties` file,
`.jks`, and `.keystore` files are ignored by Git and must never be committed.

After creating the upload keystore on a trusted workstation, populate Vault
without placing passwords in the repository:

```bash
export ANDROID_KEYSTORE_PASSWORD='...'
export ANDROID_KEY_ALIAS='xconnect-upload'
export ANDROID_KEY_PASSWORD='...'
ANDROID_KEYSTORE_BASE64="$(base64 < /secure/path/xconnect-upload.jks | tr -d '\n')"
vault kv put -mount=kv github-actions/xconnect-android-play-signing \
  ANDROID_KEYSTORE_BASE64="$ANDROID_KEYSTORE_BASE64" \
  ANDROID_KEYSTORE_PASSWORD="$ANDROID_KEYSTORE_PASSWORD" \
  ANDROID_KEY_ALIAS="$ANDROID_KEY_ALIAS" \
  ANDROID_KEY_PASSWORD="$ANDROID_KEY_PASSWORD"
unset ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD
```

Use `make build-android-play` for a release build. Pull requests do not read
this path; release branches, tags, and manual release runs use the Vault-backed
values. Rotate the upload key only with Google Play's upload-key reset process,
then update all four fields together and validate with an internal-test upload.
