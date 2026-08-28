# XConnect-One mobile enrollment boundary

## Current delivery status

Batch 05 connects XConnect-One invitations to the XConnect-APP product plugin,
Flutter lifecycle, and native mobile/deep-link entry points. It does **not**
claim that the XConnect-One mobile data plane is complete.

The native host currently reports `mobile_join_bridge_unavailable`. The app
therefore stops before exchanging an invitation and cannot acknowledge a
generation or report `joined`. A later platform batch must connect the typed
host bridge to Go `overlay/usecase.Joiner` and a protected Packet Tunnel runtime
in one reviewed transaction.

## Flow and ownership

```text
deep link / paste / import / QR SPI
              |
       strict ingress prefilter
              |
  XConnectOneEnrollmentController
              |
  XConnectOneJoinService (typed host boundary)
              |
  Go invite.Parse -> overlay/usecase.Joiner
              |
  protected Packet Tunnel host -> Apply -> ACK
```

Flutter owns presentation state only. It does not implement token exchange,
SignedConfig validation, runtime application, or ACK ordering. The Go parser is
the canonical invite validator; the Dart and native checks are fail-closed
ingress prefilters. Any future available host bridge must call the Go parser
before exchange; that requirement is covered by the shared compatibility
fixture and bridge integration gate.

## Invitation grammar

Production mobile builds accept exactly:

```text
xconnect://join/<xjt_ opaque 32-byte base64url token>?controller=https...
```

User info, fragments, extra or encoded path components, duplicate or unknown
query parameters, controller query strings, and non-HTTPS controllers are
rejected. The CLI-only explicit localhost development switch is not exposed to
the mobile product.

Opaque invitation and enrollment values are never included in Flutter status,
diagnostics, error text, or logs. A new deep link received while a one-time Join
operation is active is dropped and cannot replace the in-flight invitation.
Repeated Join actions share the same serialized operation. Clear/dispose
invalidates late results.

## Secure storage boundary

The plugin requires the typed `secret-store.probe` HostServices capability and
checks it before calling Join. The probe is distinct from granting
`secret.store`; Batch 05 does not grant a storage service that cannot yet write
mobile transient credentials safely.

| Platform | Capability probe | Batch 05 behavior |
| --- | --- | --- |
| iOS/macOS | Keychain query | Report available only when Keychain responds |
| Android | Android Keystore load | Report available only when Keystore loads |
| Windows | Credential Manager | `credential_manager_not_integrated` |
| Linux | Secret Service | `secret_service_not_integrated` |

No enrollment bearer, WireGuard private key, or invitation is persisted through
Dart preferences. The existing Go transient file store is not invoked by the
mobile product while the protected bridge is unavailable.

Batch 07 adds an operation-level `XConnectOneDeviceSessionService` for sync,
credential rotation, and leave. Its Dart results contain only
`completed/code/retryable`; no raw credential, verifier, enrollment bearer, or
WireGuard key may cross the channel. Native iOS/macOS/Android handlers remain
explicitly unavailable until the protected host owns Keychain/Keystore storage
and the complete Go Apply/ACK transaction.

## QR and protected runtime gates

`XConnectOneQrScanner` is an optional HostServices SPI. Batch 05 ships the
interface and fakes but does not grant the capability by default. Existing
camera dependencies are not treated as completed XConnect-One scanner wiring.
A later change must add permission, cancellation, lifecycle, and real-device
tests before granting it.

iOS and Android must use their protected host System VPN boundary. Apple
platforms use Packet Tunnel and never use shell commands. macOS does not request
elevated commands or change system routes for this flow. Xray/libXray remains
the only v1 runtime family.

## Rollback

This batch can be rolled back by removing product-host initialization, the
`xconnect` URL registrations, and the product channel handlers together. Since
the shipped bridge is unavailable and performs no exchange, rollback does not
need to revoke an enrollment bearer created by this batch. Do not remove only
the Flutter handler while leaving native delivery enabled; that would accept a
URL without presenting a result.

## Verification

- Flutter format, analyze, and product/full tests.
- Go full tests, race tests, vet, and the runtime policy gate.
- Shared Go/Dart invite compatibility fixture.
- Android debug compile and Apple project build checks when signing/toolchains
  are available.
- No live data-plane claim until a protected runtime Apply/ACK test passes.
