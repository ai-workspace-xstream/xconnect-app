# iOS Packet Tunnel 长时压测

用于验证 iOS Packet Tunnel 扩展在长时间运行下的内存占用与会话稳定性。

脚本：[`scripts/ios_packet_tunnel_soak.sh`](../scripts/ios_packet_tunnel_soak.sh)

---

## 为什么需要这个

`NEPacketTunnelProvider` 运行在比普通 App 严格得多的 jetsam 内存上限之下。扩展被系统回收时**不会产生崩溃日志**，用户看到的只是「莫名其妙断线」。短时间手动点几下连接是测不出来的，只有持续采样才能把两件事分开：

- 内存是否随时间单调上涨（泄漏特征）
- 会话是否在用户无感知的情况下被重启过

脚本采样扩展每秒写入 App Group 的指标快照。其中 `packet_tunnel_started_at` 是关键：这个值发生变化就说明扩展被重启了。

---

## 前置条件

1. iPhone 已通过 USB 连接并完成配对（`xcrun devicectl list devices` 能看到）
2. 设备上已安装**本仓库构建的** XConnect（`flutter run -d <udid> --release`）
3. 已在 App 内连接节点，隧道处于 connected 状态

---

## 运行

```bash
scripts/ios_packet_tunnel_soak.sh 120 30
```

参数依次为**时长（分钟）**和**采样间隔（秒）**，默认 `120 30`。

指定设备：

```bash
IOS_DEVICE=00008140-000E75903EF2801C scripts/ios_packet_tunnel_soak.sh 120 30
```

输出目录默认 `build/soak/`（可用 `SOAK_OUT` 覆盖），每次运行生成一对文件：

- `soak-<时间戳>.csv` — 逐条采样数据
- `soak-<时间戳>.log` — 会话重启、错误、以及结束时的汇总报告

> **压测期间必须持续产生真实流量**（刷视频、跑测速、正常使用均可）。空跑测到的只是扩展闲置状态，没有意义。

中断（Ctrl-C）不会丢失结果——脚本在退出时始终输出汇总报告。

---

## 单独出报告

已有 CSV 可随时重新汇总，不需要重跑：

```bash
scripts/ios_packet_tunnel_soak.sh --report build/soak/soak-20260814-140758.csv
```

---

## 采集字段

CSV 每行一次采样：

| 字段 | 含义 |
|------|------|
| `wall_clock` / `epoch` | 采样时刻 |
| `uptime_s` | 当前隧道会话已运行秒数 |
| `started_at` | 会话启动时间戳，**变化即代表扩展被重启** |
| `rss_bytes` | 扩展进程常驻内存 |
| `cpu_percent` | 扩展进程 CPU |
| `down_bps` / `up_bps` | utun 接口吞吐 |
| `go_heap_inuse` | Go 堆在用字节 |
| `go_heap_idle` / `go_heap_released` | Go 空闲堆 / 其中已归还系统的部分 |
| `go_sys` | Go runtime 向系统申请的总量 |
| `go_num_gc` | GC 累计次数 |
| `go_goroutines` | goroutine 数 |
| `last_error` | 扩展写入的最后一条错误（正常为空） |

`go_*` 字段来自 Go 侧导出的 `XrayTunnelMemoryStats`，由 `PacketTunnelMetricsSampler` 采样后写入快照。它们的作用是把进程 footprint 拆成 **Go runtime 的部分**和**其余部分**（主要是静态链接的 xray-core 常驻代码页），避免只看 RSS 就误判该往哪优化。

---

## 怎么读结果

报告末尾直接给结论：

```
samples=18  span=527s  final_uptime=921s
restarts=0  error_samples=0

  process RSS            min 41.1 MB      avg 45.7 MB      peak 48.3 MB
  go runtime Sys         min 25.6 MB      avg 25.6 MB      peak 25.6 MB
  go heap in use         min 8.3 MB       avg 9.0 MB       peak 10.4 MB
  ...
  RSS drift              -7.2 MB over the run (48.3 -> 41.1 MB)
  GC cycles              587 total, 66.8/min

  VERDICT: no session restart and no reported error.
```

判读要点：

- **`restarts` 必须为 0。** 非 0 说明扩展在压测期间被系统回收或重启过，这是最严重的信号。
- **`RSS drift` 看方向。** 在吞吐平稳的前提下持续正向增长是泄漏特征；负值或围绕基线波动属正常。
- **`go runtime Sys` 与 `process RSS` 的差值**是非 Go 部分的占用。若差值本身就很大，说明优化重点在减少链接进来的代码，而不是调 GC。
- **`cpu percent` 与 `GC cycles/min` 一起看。** GC 频率异常高且 CPU 居高不下，说明 Go 侧 soft memory limit（`go_core/bridge_apple.go` 的 `tunnelMemoryLimitBytesDefault`）压得太低，收集器在空转，应调高而不是调低。

---

## 相关调节参数

`go_core/bridge_apple.go` 中的隧道内存治理，改后需重新执行 `build_scripts/build_ios_xray.sh` 并重新部署：

| 常量 / 环境变量 | 作用 |
|------|------|
| `tunnelGCPercentDefault` / `XCONNECT_TUNNEL_GC_PERCENT` | GC 触发比例，越低堆越紧、GC 越频繁 |
| `tunnelMemoryLimitBytesDefault` / `XCONNECT_TUNNEL_MEM_LIMIT_MB` | soft memory limit，设 0 关闭 |
| `tunnelScavengeInterval` | 归还空闲内存给系统的周期 |
| `tunnelScavengeMinIdleBytes` | 低于此可回收量则跳过本次强制回收 |
