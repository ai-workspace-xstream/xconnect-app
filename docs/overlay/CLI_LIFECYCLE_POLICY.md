# XConnect-One CLI lifecycle and policy boundary

## Delivered commands

```text
xconnect up [--state-dir DIR]
xconnect down [--state-dir DIR]
xconnect leave [--state-dir DIR] [--local-only]
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

## Leave safety and Accounts dependency

Normal `leave` is fail-closed with
`device_lifecycle_contract_pending` until the versioned Accounts enrollment
self-revoke endpoint is final. The client intentionally does not call the
current user/admin device CAS path: invite-enrolled devices normally do not
have an account bearer or expected state version.

Once that contract lands, the implementation behind
`DeviceLifecycleControlPlane` must use the device-bound enrollment lifecycle
credential, wait for a successful or idempotent server revocation, and only
then run protected-host `Down`, runtime cleanup, and local cleanup.

Accounts Batch 07 extends the short-lived enrollment scope to the exact set
`overlay:config:read`, `overlay:config:ack`, and
`overlay:device:revoke`. The client accepts that closed set for join-window
self-revoke. It still deletes the enrollment bearer after successful ACK, so
this is not a durable `leave` credential. Default long-lived leave remains
blocked on the Batch 08 hash-only, rotatable device refresh credential. Until
then, normal `leave` always returns `device_lifecycle_contract_pending`, even
when local state is absent, rather than claiming remote revocation without
proof.

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

The current client SignedConfig v1 does not yet carry a policy artifact
reference, and Accounts exposes the enforcement artifact only on the internal
Gateway route. Therefore Batch 06 delivers and verifies the consumer/storage
boundary but does not claim a live client artifact fetch/apply chain. That
chain must be enabled only after a signed client policy reference and scoped
artifact endpoint become canonical.

Optional cross-repository gates can set:

```text
XCONNECT_ACCOUNTS_POLICY_FIXTURE=/path/to/network-policy-enforcement.golden.json
XCONNECT_IAC_POLICY_FIXTURE=/path/to/policy-enforcement-artifact.json
```

The Go policy tests compare trimmed physical bytes and compute the digest from
compact canonical JSON without a trailing newline.
