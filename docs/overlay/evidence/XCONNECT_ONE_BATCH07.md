# Batch 07 evidence checklist

## Contract coverage

- Canonical `xdc_<id>.<secret>` parsing, ID binding, full-token SHA-256 vector,
  exact scopes, expiry, and protected storage validation.
- Strict join exchange, session mint nonce echo, no-store response, signing-key
  overlap/window checks, rotate idempotency, and terminal revoke receipt.
- Join persists the durable credential before Apply/ACK and removes only the
  short bearer after ACK.
- Sync is resumable; runtime failure never ACKs, and ACK interruption never
  reapplies a healthy revision.
- Rotation persists a pending successor and recovers a lost response by
  probing the successor.
- Leave persists its replay nonce and terminal remote commit before local
  teardown; missing credentials fail closed.

## Platform evidence

- Linux owner-only atomic file store tests include permission, symlink,
  unknown-field, trailing-JSON, and deletion checks.
- macOS Keychain adapter tests prove the raw value is not placed in argv.
- Windows Credential Manager compiles in the Windows CLI build.
- Flutter exposes operation-level protected-host methods only. Apple/Android
  native stubs remain unavailable and never return secret fields.

## Verification commands

```text
go test -count=1 ./overlay/... ./cmd/xconnect/...
go test -race -count=1 ./overlay/... ./cmd/xconnect/...
go vet ./overlay/... ./cmd/xconnect/...
GOOS=linux   GOARCH=amd64 CGO_ENABLED=0 go test -c ./cmd/xconnect
GOOS=darwin  GOARCH=amd64 CGO_ENABLED=0 go test -c ./cmd/xconnect
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go test -c ./cmd/xconnect
flutter analyze
flutter test
bash scripts/ci/check_xconnect_one_runtime.sh
```

The repository-wide Go root and `cmd/xconnect-core` tests additionally require
the checked-out sibling `libXray` module. The overlay/CLI gate above is the
independent Batch 07 verification boundary when that sibling is absent.
