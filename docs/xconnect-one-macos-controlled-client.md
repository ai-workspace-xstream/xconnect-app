# XConnect One macOS controlled-client composition

This document records how the existing XConnect APP composes with the
independent XConnect One macOS controlled-client CLI. The APP remains a
standalone product and does not absorb the One repository.

## Final ownership model

```text
XConnect Zero
  ├── accounts: only formal API and centralized configuration source
  └── portal: Zero administration WebUI

XConnect-Gateway
  └── independent Linux relay/service node

XConnect One
  ├── independent Linux controlled-client CLI
  └── independent macOS controlled-client CLI on the user's Mac

XConnect APP
  └── optional macOS host/plugin and existing VLESS Packet Tunnel egress
```

`XConnect APP` and `XConnect One` are not one project at the source or state
layer. The APP is an optional host for the macOS One runtime adapter.

## What the APP reuses

The macOS adapter reuses the APP's existing, user-approved
`NEPacketTunnelProvider` path and VLESS/Xray egress. This includes the native
entitlements, Packet Tunnel lifecycle, utun setup, endpoint bootstrap handling
and current VLESS profile selection.

The adapter must not copy VLESS UUIDs, private keys or node database records
into One. One supplies a device-bound WireGuard overlay request; the APP
resolves the selected VLESS egress internally.

## WireGuard over VLESS

The intended data path is:

```text
One macOS WireGuard profile
  -> APP-owned local UDP relay / Packet Tunnel egress
  -> VLESS/TLS/XUDP
  -> XConnect-Gateway Xray listener
  -> XConnect-Gateway WireGuard
  -> private network
```

This is not a second VPN product and not a direct public WireGuard endpoint.
The Gateway's WireGuard listener remains co-located behind its Xray relay.

## Plugin boundary

The APP plugin is responsible for:

- receiving a versioned runtime request from One;
- checking the protected handoff file's owner, mode, digest and generation;
- mapping the request to the existing Packet Tunnel profile;
- resolving or reusing an existing APP VLESS egress;
- reporting `applied`, `down`, `failed` and `not-authorized` states;
- keeping secrets and native permission errors inside the APP boundary.

The plugin is not responsible for:

- creating Zero devices or invites;
- deciding network policy;
- issuing or refreshing One credentials;
- becoming a second configuration source;
- writing the One state directory;
- exposing a TCP control listener.

## CLI-to-APP sequence

1. One exchanges a Zero invite for the macOS device.
2. One verifies and compiles the signed config.
3. One creates a protected, digest-addressed handoff containing the local
   WireGuard profile and the selected egress reference.
4. One invokes the local APP adapter over permission-restricted IPC.
5. The APP applies the Packet Tunnel/VLESS egress and returns the applied
   generation and digest.
6. One records runtime state and sends the Zero ACK.

The APP must never acknowledge a Zero generation on One's behalf. A failed
APP apply must leave the One generation unacknowledged.

## Compatibility with the current APP

The current APP already provides the macOS Packet Tunnel and VLESS/Xray
runtime. This repository now includes an optional
`plugins/xconnect_one_bridge` package that safely invokes the independent One
CLI without changing the core APP. The dedicated native overlay adapter that
maps a WireGuard-over-VLESS request into the Packet Tunnel remains a separate
follow-up; until it exists, the APP can continue to connect its own nodes,
while One remains an independent control-plane and Linux-runtime CLI.

The existing `app-bridge` protocol remains opt-in and local. Any new runtime
method must be versioned separately and must preserve the existing rules:

- no raw Vault material, account token or VLESS secret in IPC;
- no command-line secret arguments;
- no shared mutable state directory;
- no process output or invite logging;
- no network listener for the local bridge.

## Implementation order

1. Define and test the protected macOS handoff schema.
2. Add a One macOS runtime adapter that reports `applied` only after the APP
   host confirms the Packet Tunnel profile.
3. Add the APP plugin receiver and map the WireGuard profile to the existing
   VLESS egress.
4. Add distinct macOS device/address allocation in Accounts and Portal.
5. Add a three-role UAT test: Gateway, Linux One, and local macOS One.
6. Verify recent handshakes, private ping/HTTP, sync, down and revocation.

No change in this integration permits the APP to replace Accounts or Portal,
and no change makes the macOS CLI share Linux or APP credentials.
