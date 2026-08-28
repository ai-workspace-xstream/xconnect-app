# XConnect-One durable device session

## Trust and credential boundaries

The one-time invite is consumed only for initial registration. Its exchange
response must contain a short registration bearer and one canonical device
credential. The client strictly validates HTTPS, `Cache-Control: no-store`,
token types, exact scopes, device/network/WireGuard binding, UTC whole-second
windows, Ed25519 signing keys, and the canonical credential wire format.

The raw device credential is never written to ordinary state, output, logs, or
Dart preferences. Platform storage is:

- Linux: a 0700 protected directory and atomic owner-only 0600 file;
- macOS: a generic-password Keychain item, with the secret passed on stdin and
  never in process arguments;
- Windows: Credential Manager private blob;
- iOS/Android: protected-host typed boundary only in this batch. The native
  Keychain/Keystore + VPN transaction is not yet enabled.

The existing WireGuard private key remains in ordinary 0600 Go state pending a
future platform-key-store migration. Status and diagnostics never decode or
print either secret.

## Join and sync ordering

```text
invite exchange
  -> validate response
  -> persist durable device credential
  -> persist short enrollment bearer
  -> fetch + verify SignedConfig
  -> runtime Apply + health confirmation
  -> generation ACK
  -> remove short bearer
```

If the process stops after credential storage but before short-bearer storage,
the next Join mints a fresh config-only session with the durable credential; it
does not replay the consumed invitation or create another device.

`xconnect sync` follows the same fetch/verify/Apply/ACK ordering. The device
credential itself cannot read config. It may only mint a short bearer with the
exact config read/ACK scopes. ACK failure retains that bearer for bounded
resume, while a healthy same-revision runtime is not applied twice.

Session key-ring refresh is downgrade-safe. The response ring must be valid,
have exactly one usable current key, and overlap the protected Join-trusted ring
by identical key id and public key while both declarations are usable. The
SignedConfig is verified under the old ring. The candidate ring is persisted
only after Apply, ACK, and last-known state succeed.

## Rotation and leave recovery

`xconnect credential rotate` generates the successor locally and atomically
stores it as pending before sending only its id and SHA-256 verifier. The
verifier is SHA-256 of the UTF-8 bytes of the exact full `xdc_...` value. The
IAC golden vector is locked in Go tests. If the rotation response is lost, the
next command probes the pending credential; a successful session mint promotes
it without generating another secret.

Normal `leave` directly uses the durable credential. A UUID request nonce is
stored in `device-operation.json` before network access. The remote terminal
receipt is recorded before runtime teardown. Cleanup failure retains the
credential and committed operation checkpoint; retry finishes local cleanup
without claiming a second revocation. `--local-only` remains an explicit
recovery path and does not report remote revocation.

## Commands and stable failures

```text
xconnect sync [--state-dir DIR] [--signed-config-v2]
xconnect credential rotate [--state-dir DIR]
xconnect leave [--state-dir DIR]
xconnect leave --local-only [--state-dir DIR]
```

Relevant stable failures include `device_credential_missing`,
`device_credential_expired`, `device_credential_invalid`,
`device_credential_storage_unavailable`, `device_session_invalid`, and the
existing signed-config/runtime errors. Error text contains only operation and
stable code.

`--signed-config-v2` is a deliberate rollout switch. It requests only the v2
media type and requires the signed same-origin policy reference and policy
artifact to validate before runtime Apply. It rejects redirects and never
downgrades to v1 if the v2 producer is unavailable.

## Platform limitation

Linux reuses the verified Xray-core + WireGuard desktop runtime. macOS CLI
still requests only the protected Packet Tunnel host and never invokes sudo or
system route commands. Windows remains behind the Service runtime boundary.
Mobile native hosts currently return `protected_device_session_unavailable`;
no mobile data-plane completion is claimed.
