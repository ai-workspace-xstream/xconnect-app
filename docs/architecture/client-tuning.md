# Client transport tuning

The control plane can adjust a small, fixed set of transport knobs on every
client without shipping a new app build. Servers are tuned separately by
`xconnect-edge-agent` (see its API reference, `tuning` on
`GET /api/agent-server/v1/users`).

## Fetch

After each successful node sync (login, the ten-minute refresh and manual
sync) the client requests `GET /api/agent-server/v1/client-tuning` with the
same session headers as `GET /api/agent-server/v1/nodes`.

| Response | Client behaviour |
| --- | --- |
| `200` with a version 1 document | Stored as the last known good profile |
| `404` | No tuning: the stored profile is dropped and built-in defaults apply |
| Anything else, or an unknown `version` | Logged; the last known good profile stays |

A tuning failure never fails the node sync. Signing out or switching accounts
clears the profile and discards any response still in flight for the old
session; that older sync is not recorded as a success. Values apply the next
time a profile is prepared for connect, so a change reaches a connected client
on its next reconnect.

## Document

```json
{
  "version": 1,
  "revision": "2026-10-14.1",
  "defaults": {
    "xhttp": {
      "mode": "stream-up",
      "xmuxMaxConcurrency": "2-4",
      "xmuxHMaxRequestTimes": "600-900",
      "xmuxHMaxReusableSecs": "1800-3000",
      "scMaxEachPostBytes": 1000000,
      "scMinPostsIntervalMs": 30
    },
    "dns": { "dohTimeoutMs": 1500, "parallelQuery": false },
    "tunnel": { "goMemoryLimitMB": 64, "goGCPercent": 40 }
  },
  "platforms": { "ios": { "xhttp": { "xmuxMaxConcurrency": "1-2" } } },
  "nodes": { "<node id from /nodes>": { "xhttp": { "scMaxEachPostBytes": 524288 } } }
}
```

Resolution order is `defaults`, then `platforms[<ios|android|macos|windows|linux>]`,
then `nodes[<node id>]`; each layer replaces only the fields it sets. DNS knobs
use `defaults` and `platforms` only.

| Field | Accepted values | Applied to |
| --- | --- | --- |
| `xhttp.mode` | `auto`, `stream-up` | XHTTP `mode` |
| `xhttp.xmuxMaxConcurrency` | 1–128, number or `"a-b"` | `extra.xmux.maxConcurrency` |
| `xhttp.xmuxHMaxRequestTimes` | 1–10000 | `extra.xmux.hMaxRequestTimes` |
| `xhttp.xmuxHMaxReusableSecs` | 1–86400 | `extra.xmux.hMaxReusableSecs` |
| `xhttp.scMaxEachPostBytes` | 65536–4194304 | `extra.scMaxEachPostBytes` (packet-up upload chunk) |
| `xhttp.scMinPostsIntervalMs` | 1–1000 | `extra.scMinPostsIntervalMs` |
| `dns.dohTimeoutMs` | 500–8000 | `timeoutMs` of the DoH upstreams (default 1500) |
| `dns.parallelQuery` | `true` / `false` | `dns.enableParallelQuery` |
| `tunnel.goMemoryLimitMB` | `0`, or 32–256 | Go soft memory limit in the Apple Packet Tunnel; `0` removes it |
| `tunnel.goGCPercent` | 20–200 | Go GC target percentage in the Apple Packet Tunnel |

Out-of-range values and unknown fields are ignored. Nothing in the document
can change addresses, outbounds, routing or TLS settings.

## Apple Packet Tunnel runtime

`tunnel` values reach the Packet Tunnel through the typed Pigeon
`TunnelProfile` and the persisted `providerConfiguration["options"]`, and the
extension passes them to the Go bridge's `StartXrayTunnelWithFdTuned`. Absent
values keep the built-in defaults (64 MiB, GC 40); an out-of-range value fails
the start rather than being guessed. They apply when the tunnel next starts:
a running session keeps its values, and stopping or a failed start restores
the process defaults.

The memory limit is a soft cap on the Go heap only, not on the process.
On iOS the extension is killed by jetsam once its whole physical footprint
(Go, Swift and Network Extension) passes the Packet Tunnel cap, which is far
below 256 MiB; a Go limit near or above that cap protects nothing, so the
upper bound is not a safe iOS value. Choose values from device soaks that
watch the footprint peak and JetsamEvent reports. macOS has more headroom.

When tuning changes, or is withdrawn by a `404` or sign-out, the client
rewrites the persisted runtime config and profile options so an on-demand or
system relaunch uses current values without Flutter running. This only
refreshes an existing VPN configuration; it never creates one.

Both platforms report, through `TunnelMetricsSnapshot`, the physical
footprint and its peak, resident size, Go heap and sys, GC count, and the
limit and GC percent in effect. The client logs them at most once a minute.
Sampled figures do not replace the footprint peak or JetsamEvent evidence.

## Rules

- A mode or xmux concurrency the user saved in settings wins over tuning,
  including when the saved value is the local default. Saving one field (for
  example ALPN) does not pin the others.
- Tuned values are written inside XHTTP `extra`, because Xray replaces every
  field except host, path and mode with `extra` when it is present.
- Each tuned XHTTP value is recorded in the saved profile, under the
  top-level `xconnectTuning` key, with the value the profile held before.
  When tuning stops sending a field — a `404`, a sign-out, or a `200`
  document that omits it — the next connect restores that original value.
  A value changed outside tuning after it was applied is kept.
- `scMaxEachPostBytes` must not exceed the node's `xhttpScMaxEachPostBytes`
  (Xray's default is 1000000 on both sides).
