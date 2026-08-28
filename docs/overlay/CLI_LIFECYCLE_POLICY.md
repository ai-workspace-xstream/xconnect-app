# XConnect-One CLI lifecycle and policy boundary

## Delivered commands

```text
xconnect up [--state-dir DIR]
xconnect down [--state-dir DIR]
xconnect sync [--state-dir DIR] [--signed-config-v2]
xconnect leave [--state-dir DIR] [--local-only]
xconnect credential rotate [--state-dir DIR]
xconnect admin invite create --network-id ID [--device-id ID]
    [--platform PLATFORM] [--expires-in SECONDS] [--output json|uri]
xconnect policy explain --network-id ID --revision N
    --source SELECTOR --destination SELECTOR --protocol tcp|udp|icmp --port N
```

`up` reapplies the acknowledged last-known configuration only when the runtime
is not already healthy. It never fetches or acknowledges configuration.
`down` stops only runtime resources proven by XConnect-owned metadata and keeps
the encrypted-network state needed by a later `up`. Both commands are
idempotent. `status` and `down` still surface or stop an owned runtime revision
when a crash left runtime metadata but no last-known state.

All mutating CLI operations use an atomic per-state-directory operation lock.
A live operation returns `operation_in_progress`; a lock older than five
minutes is recoverable after a crash. State and runtime writes retain their
existing 0700-directory, 0600-file, and atomic-rename requirements.

## Durable session and leave safety

Invite exchange returns both the short `xenr_` registration bearer and one
device-bound durable credential. The durable credential is written to the
platform protected store before configuration Apply. ACK then removes the
short bearer; it never removes the durable credential.

`sync` authenticates with the durable credential only to mint a maximum
15-minute `xenr_` with the exact config read/ACK scopes. It validates the
nonce, device/network binding, lifetime, and signing-key ring. A candidate ring
must overlap the Join-trusted ring by `key_id + public_key`; SignedConfig is
still verified under the old durable ring, and the candidate ring is committed
only after runtime Apply, generation ACK, and last-known-state commit. Failed
fetch, signature, Apply, or ACK therefore cannot poison durable trust.

Normal `leave` calls the device-bound revoke route with a persisted UUID nonce
and canonical request idempotency key. A terminal or replayed receipt is
required before runtime cleanup. The credential and replay checkpoint remain
available across interrupted cleanup. Local state is removed only after remote
commit and protected credential deletion. Missing/expired credentials fail
closed; they never fall back to account/admin or legacy enrollment routes.

`leave --local-only` is an explicit recovery operation. It stops and cleans
the local runtime, and can clear an interrupted Join checkpoint even before a
last-known state exists. A normal leave never treats that partial enrollment
as server-revoked. Local cleanup removes only these known XConnect files:

- `join-checkpoint.json`
- `state.json`
- `config-contract.json`
- `signing-keys.json`
- `enrollment-secret.json`
- `policy-state.json`
- `device-operation.json`

Unknown files, symlinks, directories, and non-0600 state artifacts are never
deleted. Cleanup fails closed or reports retained unknown files.

## Platform host chain

| Platform | CLI runtime call chain | Current state |
| --- | --- | --- |
| Linux | CLI → shared Go use case → owned external Xray/WireGuard runtime | `up`/`down` operational with required dependencies and privilege |
| macOS | CLI → `ProtectedHostIPC` → XConnect-APP → Packet Tunnel provider | typed boundary; IPC transport not yet connected, fail-closed |
| Windows | CLI → `ProtectedHostIPC` → Windows Service | typed boundary; Service IPC not yet connected, fail-closed |
| iOS/Android | app → protected mobile tunnel host | no shell CLI; typed boundary remains fail-closed |

The macOS CLI never invokes `sudo`, `wg-quick`, or system route commands.

## One-time invite output

`admin invite create` calls `POST /api/overlay/v1/join-tokens` with an account
Bearer token. It requires a strict JSON response and `Cache-Control: no-store`.
The one-time URI appears exactly once on stdout: either as `join_uri` in JSON or
as the sole `--output uri` line. It is never written to stderr, logs, status,
diagnostics, or local state by this command.

## Policy explain and enforcement consumer

`policy explain` first reads the requested policy revision metadata and then
calls `POST /api/overlay/v1/policies/{revision}/explain`. Output is limited to
the requested network, revision/generation, final action, rule ID, reason, and
resolved device IDs. Unknown response fields, email-like identities, and
unscoped tenant details are rejected.

The local enforcement consumer uses the Accounts/IaC/Gateway v1 golden digest
`58941760a9ab4568d2e72a6f34a2cede891d8e678346da8e886d86263e5b780c`.
It accepts only an opaque `VerifiedReference` bound to an already verified
SignedConfig or Gateway snapshot. The type has no public constructor in v1,
because the current client SignedConfig has no policy reference; raw CLI,
caller-provided expiry, and HTTP fields therefore cannot construct a policy
acceptance. The consumer enforces:

- schema/compiler/network identity and default deny;
- the exact protected-flow list in canonical order;
- deny rules before accept rules, then rule ID order;
- sorted unique source/destination/protocol/port arrays;
- no unknown fields or PII-bearing device identities;
- compact canonical JSON digest (physical trailing whitespace is ignored);
- non-expired trusted reference and monotonic generation floor;
- same generation/same digest idempotence and different-digest rejection.

The accepted generation/digest/expiry storage boundary is `policy-state.json`
and is shown by `status` and `diagnose`. It becomes reachable only when a
canonical signed verifier can issue the opaque reference. Local policy remains
advisory; Gateway enforcement is authoritative.

`sync --signed-config-v2` explicitly opts into the policy-bound SignedConfig
v2 contract. Default `sync` remains strict v1 throughout the producer rollout.
V2 requires `Accept: application/vnd.xconnect.signed-config.v2+json`,
`Vary: Accept`, and the exact v2 response media type; it never silently falls
back to v1. After Ed25519 verification, the client derives the only permitted
same-origin relative artifact path from the signed policy generation/digest.
It rejects absolute paths, redirects, unexpected media types, digest mismatch,
and replay (including an equal generation with another digest). Config and
policy are both validated before runtime Apply; runtime readback and ACK occur
before advancing the SignedConfig/policy floors, preserving last-known-good
state on any failure. Accounts must serve the scoped artifact endpoint before
this opt-in flag is enabled in a rollout.

Optional cross-repository gates can set:

```text
XCONNECT_ACCOUNTS_POLICY_FIXTURE=/path/to/network-policy-enforcement.golden.json
XCONNECT_IAC_POLICY_FIXTURE=/path/to/policy-enforcement-artifact.json
```

The Go policy tests compare trimmed physical bytes and compute the digest from
compact canonical JSON without a trailing newline.
