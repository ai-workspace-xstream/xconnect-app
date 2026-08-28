# Batch 05 evidence checklist

## Security assertions

- [x] One-time Join operations are serialized in the Flutter model.
- [x] Deep links arriving during Join do not replace the in-flight invite.
- [x] Clear/dispose invalidates late results and clears in-memory invite state.
- [x] Flutter status JSON contains stable codes only.
- [x] Flutter product code contains no overlay HTTP endpoint implementation.
- [x] Flutter product code does not use plaintext preferences for secrets.
- [x] Mobile production rejects HTTP controllers, including localhost.
- [x] Go remains the canonical invite parser and CLI reuses it.
- [x] Runtime-unavailable hosts do not exchange, Apply, ACK, or report joined.

## Platform assertions

- [x] Android handles cold and `singleTop` warm intents.
- [x] iOS handles application and scene URL lifecycle callbacks.
- [x] macOS registers and validates the same URL shape.
- [x] Keychain and Android Keystore are capability-probed.
- [x] Windows Credential Manager and Linux Secret Service gaps are explicit.
- [x] QR scanning is optional and ungranted until real host integration tests.

## Runtime evidence to attach before merge

- Flutter format/analyze/test output.
- Go test/race/vet output and runtime-gate output.
- Android/Apple compile evidence where available.
- Commit SHA and clean worktree status.

## Local verification (2026-08-28)

| Check | Result |
| --- | --- |
| Flutter full test suite | PASS, 151 tests |
| Flutter analyze | PASS, zero issues |
| XConnect-One product tests | PASS, 41 tests |
| Go full tests | PASS |
| Go overlay/CLI race tests | PASS |
| Go vet and runtime policy gate | PASS |
| Go CLI cross-build | PASS, Linux/macOS/Windows × amd64/arm64 |
| iOS unsigned debug build | PASS |
| macOS debug compile with code signing disabled | PASS |
| Android native compile | NOT RUN: Android SDK is not configured on this host |
| Android manifest and Apple plist validation | PASS |

The normal macOS Flutter build stopped at local provisioning-profile lookup;
the same workspace then compiled successfully with code signing disabled. No
real-device data-plane test was run, and the product continues to report the
mobile Join bridge unavailable.
