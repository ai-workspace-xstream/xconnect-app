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

A tuning failure never fails the node sync. Signing out clears the profile.
Values apply the next time a profile is prepared for connect, so a change
reaches a connected client on its next reconnect.

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
    "dns": { "dohTimeoutMs": 1500, "parallelQuery": false }
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

Out-of-range values and unknown fields are ignored. Nothing in the document
can change addresses, outbounds, routing or TLS settings.

## Rules

- A mode or xmux concurrency the user changed in settings wins over tuning.
- Tuned values are written inside XHTTP `extra`, because Xray replaces every
  field except host, path and mode with `extra` when it is present.
- A tuned value stays in the saved profile until the server sends another
  one. To roll a field back, send its default value rather than omitting it.
- `scMaxEachPostBytes` must not exceed the node's `xhttpScMaxEachPostBytes`
  (Xray's default is 1000000 on both sides).
