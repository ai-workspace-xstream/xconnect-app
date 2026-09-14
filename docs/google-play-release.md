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

The field mapping and least-privilege Vault contract are documented in
[Vault Android upload signing](vault-android-upload-signing.md). `storeFile` is
a runner-local path and is not stored in Vault.

## Android Studio Quail 4 local release

Android Studio can create the upload keystore and build the same release
variant used by CI:

1. Install the official **Flutter** plugin from **Settings/Preferences →
   Plugins → Marketplace**. The Dart plugin is installed as its dependency.
2. Restart Android Studio and open the repository root (the directory that
   contains `pubspec.yaml`), not only `android/`:
   `/Users/shenlan/workspaces/ai-workspace-xstream/xconnect-app`.
3. Set Flutter SDK to `/Users/shenlan/.local/devtools/flutter`, Android SDK to
   `/Users/shenlan/.local/devtools/android-sdk`, and Gradle JDK to
   `/Users/shenlan/.local/devtools/jdk17/Contents/Home`.
4. Run `flutter pub get`, then **File → Sync Project with Gradle Files**. If
   old unresolved references remain, use **File → Invalidate Caches / Restart**.
5. Choose **Build → Generate Signed Bundle / APK**, select **Android App
   Bundle**, and create or select an upload keystore. Use a validity of at
   least 25 years, keep the `.jks` file outside version control, and never
   commit its passwords.
6. For a local Gradle build, save `android/key.properties` with these keys:
   `storePassword`, `keyPassword`, `keyAlias`, and `storeFile`. Prefer an
   absolute `storeFile` path so Android Studio and command-line builds resolve
   the same file.
7. From the repository root run `make build-android-play`. The target requires
   release signing and rejects debug certificates before reporting success.

The package name is immutable: `plus.svc.xconnect`. Increment the `+BUILD`
number in `pubspec.yaml` for every upload. On the first upload, use the Play
Console **App signing** section to enable Play App Signing; upload the AAB
signed with the upload key, then complete the internal-testing rollout before
promoting to closed or production testing.

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
