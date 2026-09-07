# xconnect_one_bridge

Optional XConnect APP composition package for the independent XConnect One
CLI. It is intentionally not referenced by the root APP `pubspec.yaml`, so
the existing application build and connection path are unchanged.

The package starts a released One binary through the local `app-bridge`
JSONL protocol. It provides `negotiate`, `join`, `sync`, `status`, `diagnose`
and `leave` operations, with an APP-owned absolute state directory.

The package does not:

- open a network listener;
- import One source or state files;
- log invitations, credentials, private keys, stderr or raw responses;
- copy XConnect APP VLESS secrets into One;
- replace the existing APP Packet Tunnel or VLESS runtime.

The host application must explicitly opt in, supply a released binary path,
use a dedicated state directory, and ask the user before `leave`.
