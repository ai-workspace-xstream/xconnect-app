# Batch 06 evidence checklist

## Functional and security assertions

- [x] `up` and `down` are idempotent and do not send config ACKs.
- [x] Linux runtime down/up retains trusted metadata and refuses stale PIDs.
- [x] Cleanup removes only verified XConnect runtime/state artifacts.
- [x] Normal leave waits for a server lifecycle contract; local-only is explicit.
- [x] Missing local state never becomes false proof of remote revocation.
- [x] Invite creation emits the raw one-time URI only once on stdout.
- [x] Policy explain output is strict, scoped, and PII-free.
- [x] Policy artifact consumer matches the Accounts/IaC canonical golden.
- [x] Policy generation replay, wrong digest/network, expiry, and unsafe JSON fail closed.
- [x] Caller-supplied expiry cannot construct the opaque verified policy reference.
- [x] macOS/Windows/mobile protected hosts remain typed and unavailable.

## Verification

- `go test -count=1 ./overlay/... ./cmd/xconnect/...`: passed.
- `go test -race -count=1 ./overlay/... ./cmd/xconnect/...`: passed.
- `go vet ./overlay/... ./cmd/xconnect/...`: passed.
- `scripts/ci/check_xconnect_one_runtime.sh`: passed.
- `dart format --output=none --set-exit-if-changed lib test`: 95 files,
  zero changes.
- `flutter analyze`: no issues.
- `flutter test --no-pub -r compact`: 151 tests passed.
- Cross-compiled `go_core/cmd/xconnect` for Linux, macOS, and Windows on
  amd64 and arm64: passed.
- Accounts Batch 07 and IaC Batch 05 policy fixture environment gates: passed.

The isolated `/tmp` worktree cannot run `go test ./...` because `go_core/go.mod`
uses the repository-topology-relative `replace ../libXray`, and no sibling
`libXray` checkout exists inside that temporary worktree. All changed Go
packages and their dependency graph are covered by the scoped test, race, vet,
runtime gate, and cross-build commands above. Batch 06 changes no Apple or
Android native source, so signed native application builds were not repeated.

The commit SHA, remote SHA, and final clean-worktree check are recorded in the
branch handoff after commit and push.

## Known contract dependency

Accounts Batch 07 owns the enrollment-token self-revoke route and response.
Until it is canonical, default `leave` returns
`device_lifecycle_contract_pending` before changing runtime or state. The
client does not invent or bind to the user/admin CAS endpoint.

The canonical short enrollment scope now includes
`overlay:device:revoke`, but the bearer is deleted after ACK and is explicitly
not retained as a durable leave credential.

SignedConfig v1 also has no client policy reference and the existing artifact
route is Gateway-internal. The strict consumer and persistent floor are ready,
but live client fetch/apply remains disabled until that signed contract exists.
