# Handoff: iOS Packet Tunnel fails on cellular — DNS deadlock

**Date**: 2026-08-14
**Device**: iPhone 16e (iPhone17,5), iOS 27.0, UDID `00008140-000E75903EF2801C`
**Node under test**: `tky-proxy.svc.plus:443`, VLESS over XHTTP/TLS
**Status**: root cause **confirmed with engine logs**; fix **not implemented**, awaiting a decision between two approaches.

---

## 1. The symptom

Tunnel connects (`NEVPNStatus == connected`, utun up, engine started), but carries no traffic on cellular. The app-side data-plane check reports:

```
隧道已连接但出站不可用，19.7s 内 10 次探测均无法建立连接（弱网或节点不可达）:
8.8.8.8:443: SocketException: Connection failed
(OS Error: No route to host, errno = 65), address = 8.8.8.8, port = 443
```

Reported by the user as intermittent ("弱网偶发"). It is not intermittent in the way that phrasing suggests — see §3.

**Decisive framing given by the user**: *"只要连接上 WiFi APP 就能工作"* — it works on Wi-Fi, fails on 5G.

---

## 2. Root cause: DNS circular dependency

Confirmed by the engine's own error log (see §5 for how to collect it):

```
proxy/tun: processing from udp:10.0.0.2:57191 to udp:1.1.1.1:53
app/dispatcher: taking detour [proxy] for [udp:1.1.1.1:53]
transport/internet/splithttp: XHTTP is dialing to tcp:tky-proxy.svc.plus:443
transport/internet/splithttp: failed to GET https://tky-proxy.svc.plus/split/ >
  dial tcp: lookup tky-proxy.svc.plus: no such host
```

**131 × `no such host`, 0 successful outbound dials** in one session.

The cycle:

1. The tunnel installs `NEDNSSettings(servers: [1.1.1.1, 8.8.8.8])` with `matchDomains = [""]`, so **every DNS query on the device is captured into the tunnel**.
   `ios/PacketTunnel/PacketTunnelProvider.swift` → `buildNetworkSettings`.
2. Routing rule #1 in the node config sends `tun-in` tcp/udp **port 53 → `proxy`**, so DNS must traverse the VLESS proxy. (This is the "Tunnel DNS via Proxy" feature.)
3. The proxy's `vnext.address` is a **domain**, `tky-proxy.svc.plus`, so the engine must resolve it before it can dial.
4. That resolution uses the **system resolver inside the extension process**, which step 1 just repointed into the tunnel → the query needs the proxy → the proxy needs the resolution. **Deadlock.**

`no such host` returns immediately, the dial fails instantly, and tun2socks surfaces `EHOSTUNREACH` to the app — which is why the app sees `errno 65` with no timeout delay.

### Why Wi-Fi works and 5G does not

DNS cache state. On Wi-Fi the server domain has typically already been resolved (warm cache in the extension/system), so the first dial succeeds and the tunnel then works normally. A fresh cellular attach changes resolver state and leaves a cold cache, so the very first resolution has to go through the tunnel and deadlocks.

This is also the real source of the "偶发" character: **it depends on whether `tky-proxy.svc.plus` is already cached at the moment the tunnel starts**, not on signal quality.

---

## 3. Hypotheses tested and **disproven** — do not re-tread

| Hypothesis | Verdict | Evidence |
|---|---|---|
| Weak/flaky cellular signal | **Wrong** | Failure is an immediate `EHOSTUNREACH`, never a timeout. 131 identical instant failures. |
| Carrier is IPv6-only (464XLAT/NAT64), config forces IPv4 | **Wrong** | Added `getifaddrs` diagnostic: egress reports `pdp_ip0: v4=1 v6=3`. The link is dual-stack and **has** IPv4. |
| Packet Tunnel extension failed to start / bad tun fd | **Wrong** | Every recorded session reaches `engine_started`; `utun10 created` / `utun10 up` in the engine log. |
| The app-side probe is a false positive | **Wrong** | utun throughput sampled at 0 B/s up **and** down for 30+ s while the probe was failing. The probe's verdict is correct. |
| `sockopt.interface` binding to `pdp_ip0` breaks the outbound | **Not the cause** | The dial never gets as far as a socket — it fails at name resolution. Left unexamined beyond that. |

Note: IPv4 **is** hardcoded in three places (`queryStrategy: "UseIPv4"` in `lib/templates/xray_config_template.dart` and twice in `lib/services/dns/dns_control_plane.dart`; `tun46Setting: 0` / `defaultNicSupport6: false` hardcoded in `lib/utils/native_bridge.dart:881`). This is real and worth revisiting — `defaultNicSupport6` never detects anything, it is a constant `false` — but **it is not the cause of this bug**.

---

## 4. Proposed fix (not implemented)

Break the cycle so the proxy dial never depends on in-tunnel DNS.

**Option 1 — resolve before connecting, dial by IP (recommended).**
Resolve the server domain in the app *before* starting the tunnel, write the literal IP into `vnext.address`, and add that IP to `ipv4ExcludedRoutes` so its packets never enter utun. Safe here because the config already sets `tlsSettings.serverName` and `xhttpSettings.host` to the domain explicitly, so SNI and TLS validation are unaffected by swapping the dial address.
Trade-off: needs a resolution step and a refresh policy for when the server IP changes.

**Option 2 — add the server domain to the direct-DNS rule.**
The config already has `dns-direct-primary` / `dns-direct-secondary` with a `domains` allowlist (`apple.com`, `localhost`, connectivity-check hosts, …) routed to `direct`. The **proxy's own domain is missing from that list**.
Caveat: the failing lookup in the log is `dial tcp: lookup …`, i.e. Go's **system** resolver, not xray's internal DNS. So this alone may not fix it unless outbound address resolution is also routed through xray's internal DNS. Treat as a complement to Option 1, not a replacement.

Whichever is chosen, keep the app-side data-plane probe as the regression signal: it caught this correctly.

---

## 5. Diagnostic tooling added during this session

All of it is currently **uncommitted** (see §6). It is what made the root cause visible; recommend keeping it.

### App logs persisted to disk
`lib/utils/app_log_file.dart` (merged in PR #49). App logs previously lived only in memory, so nothing survived on a physical device. Now mirrored to a bounded rotating file under `Library/Caches` (per Apple's iOS Data Storage Guidelines — regenerable diagnostic data must not sit in a backed-up location).

```bash
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier plus.svc.xconnect \
  --source Library/Caches/logs/app.log --destination ./app.log
```

### Engine error log into the App Group  ← this is what solved it
`PacketTunnelProvider.attachEngineErrorLog` injects `log.error` pointing at the shared App Group container and truncates it per session.

```bash
xcrun devicectl device copy from --device <UDID> \
  --domain-type appGroupDataContainer --domain-identifier group.plus.svc.xconnect \
  --source logs/xray-tunnel.log --destination ./xray.log
```

### Egress address families
`PacketTunnelProvider.describeAddressFamilies` counts AF_INET/AF_INET6 addresses on the egress interface at startup, written to the App Group key `packet_tunnel_egress_info`. Distinguishes an IPv6-only link from a weak one — both look identical at the socket layer.

### Tunnel state / metrics snapshot
Key `packet_tunnel_metrics_snapshot` in `group.plus.svc.xconnect`, plus `packet_tunnel_last_error` and `packet_tunnel_started_at`.

```bash
xcrun devicectl device copy from --device <UDID> \
  --domain-type appGroupDataContainer --domain-identifier group.plus.svc.xconnect \
  --source Library/Preferences/group.plus.svc.xconnect.plist --destination ./g.plist
plutil -p g.plist
```

> `plutil -extract` prints its "missing key" diagnostic on **stdout** and exits non-zero. Always guard with `if out="$(plutil -extract … )"`, or the error text ends up in your data.

### Soak harness
`scripts/ios_packet_tunnel_soak.sh` (+ `Runbook/iOS-Packet-Tunnel-Soak.md`), merged in PR #48. Samples RSS/CPU/throughput/Go heap/GC/goroutines, flags session restarts and errors, summarises on exit, and re-summarises an existing CSV with `--report`.

### LLDB attach does not work on this device
`flutter run --debug` fails on iOS 27.0: LLDB cannot find the on-disk shared cache, the Dart VM Service is not discovered within 60 s, and the process is SIGKILLed. **Do not rely on an attached debug session here** — use the persisted logs above.

---

## 6. Repository state

**Merged**
- PR #48 — data-plane probe, Packet Tunnel footprint work (Go GC pacing + scavenger, Go memory exported into the metrics snapshot), soak script + runbook.
- PR #49 — probe budget made a hard bound + exponential backoff; app logs persisted to `Library/Caches`; in-memory log buffers bounded to 300 entries.

**Released**
- `main` @ `1e8b7c0`, `release/v1.0` cut from it, tag `v2026.8.14` pushed.
- Branch ruleset "Release Branch Protection (release/\*)" applied (blocks deletion, force-push, non-linear history).
- `pubspec.yaml` was bumped to `1.0.0+6` on main, then changed to `1.0.0+1` in the working tree per "new software line" — **uncommitted**.
  ⚠️ App Store Connect requires strictly increasing build numbers **within an app record**. `+1` will be rejected if that record already has a build 5. Fine only for a genuinely new record.

**Uncommitted working-tree changes** (branch `main`)

| File | What |
|---|---|
| `ios/PacketTunnel/PacketTunnelProvider.swift` | engine error log into App Group; egress address-family diagnostic |
| `lib/services/tunnel_data_plane_probe.dart` | `suspended` outcome — an app suspended mid-probe is inconclusive, not a failure |
| `lib/utils/native_bridge.dart` | removed the duplicate `budget` default that silently shadowed the probe's own |
| `test/services/tunnel_data_plane_probe_test.dart` | +2 regression tests (suspension; slow-but-valid runs still judged) |
| `pubspec.yaml` | `1.0.0+1` |
| `docs/ios-design.md` | user's own edit (soak command line) |

`flutter analyze lib test` clean; `flutter test` 89 passing.

---

## 7. Two probe bugs found and fixed along the way

Both were introduced in PR #48 and surfaced only because logs now persist.

1. **Budget was not a bound.** Field reports showed 17.2 s and 16.1 s against a 12 s budget: the deadline was only checked *between* attempts, so a stacked DNS timeout plus two fallback connect timeouts overran it. Every call is now clamped to the remaining budget.
2. **Duplicate default shadowed the real one.** `NativeBridge.verifyTunnelDataPlane` declared its own `budget = 12s`, overriding the probe class's 20 s. Raising the probe's default had no effect on the app at all. Removed.

Also: retries now back off exponentially. A refused route fails instantly, so a fixed 600 ms interval spent the whole budget on retries that could not succeed (19 attempts in 16 s bought nothing).

And a third, still uncommitted: **wall-clock deadlines are invalid across iOS app suspension**. A field log showed "221.9 s, 3 attempts" against a 12 s budget — iOS suspended the app mid-probe, time ran on, the budget expired without a single extra sample, and a failure was declared from ~3 s of actual testing. Such runs now return `TunnelDataPlaneOutcome.suspended`, which is explicitly **not** a conclusive failure.

---

## 8. Reproduction

1. Build and install to the device: `flutter run -d <UDID> --release`.
2. On the phone: **turn Wi-Fi off, leave 5G on.**
3. Connect the tunnel in the app.
4. Pull `logs/xray-tunnel.log` from the App Group (§5) and grep for `no such host`.

Expect `taking detour [proxy] for [udp:1.1.1.1:53]` followed immediately by `dial tcp: lookup tky-proxy.svc.plus: no such host`, repeating, with zero successful dials.

---

## 9. Open questions

- Which fix approach (§4). Option 1 changes config generation, which affects **all** platforms, and `release/v1.0` is already cut — so this needs a deliberate call on whether it lands on `main` only or is cherry-picked to the release line.
- Should the diagnostic instrumentation (§5) ship in release builds, or be gated? It is currently unconditional. The engine log is `loglevel: info` and will be chatty — 98 KB in roughly one minute.
- `defaultNicSupport6` is a hardcoded `false` that never detects anything. Separate from this bug, but it means IPv6 is off by construction on every platform.
- The extension's egress selection reads `monitor.currentPath` immediately after `monitor.start()`, which is asynchronous — an earlier trace recorded `egress = "unavailable"`, so the race is real. Not implicated in this bug, but it is a latent one.
