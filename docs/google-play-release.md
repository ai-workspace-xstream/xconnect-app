# Google Play release checklist

XConnect is published as an Android application with the immutable package name
`plus.svc.xconnect`. The value is declared in `android/app/build.gradle` and
must not change after the Play Console app is created.

## Build outputs

The Android CI lane creates:

- `build/app/outputs/bundle/release/app-release.aab` — the signed App Bundle to
  upload to Google Play (internal testing first).
- `build/app/outputs/flutter-apk/app-release.apk` — device smoke-test artifact.

The version name and version code come from `pubspec.yaml`. Increment the build
number for every Play upload; Google Play rejects a reused version code.

## Signing contract

Release lanes on `main`, version tags, and manual dispatch require these
Vault-backed environment variables from
`kv/data/github-actions/xconnect-app`:

`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`,
and `ANDROID_KEY_PASSWORD`.

The workflow materializes the keystore only for the build and removes it when
the step exits. Never commit `android/key.properties`, a keystore, or passwords.
Pull request verification builds may use the documented debug-signing fallback,
but those artifacts must not be uploaded to Play.

## Play listing and policy information

- Developer name: **XWork Technologies LLC**.
- Organization website: <https://xworktech.com>.
- Privacy policy: <https://xworktech.com/privacy>.
- Support/contact: <https://xworktech.com/support> and
  <https://xworktech.com/contact>.
- Complete the Play Console Data safety, content rating, target audience, app
  access, screenshots, and support email declarations from the shipped build.
- XConnect uses Android `VpnService` for a system-level encrypted tunnel.
  Complete Play's VPN declaration and ensure the listing and privacy policy
  describe the actual data handling and permissions.

After the signed AAB passes internal testing, promote through closed testing
before requesting production access.
