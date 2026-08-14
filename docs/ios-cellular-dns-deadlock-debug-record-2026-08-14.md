# XConnect iOS 蜂窝网络 DNS 死锁 Debug 完整记录

**日期**：2026-08-14（Asia/Shanghai）
**仓库**：`ai-workspace-xstream/xconnect-app`
**最终分支**：`main`
**合并 commit**：`27a312d3415a436beca2f03ad5e922107ded23c8`
**PR**：[PR #50](https://github.com/ai-workspace-xstream/xconnect-app/pull/50)（初始修复，已合并）、[PR #51](https://github.com/ai-workspace-xstream/xconnect-app/pull/51)（本次清理与加固，已合并）
**最终发布 tag**：`v2026.08.14-1938`
**测试设备**：iPhone 16e（`iPhone17,5`），iOS 27.0，UDID `00008140-000E75903EF2801C`
**测试节点**：`tky-proxy.svc.plus:443`，VLESS over XHTTP/TLS

## 1. 结论摘要

本次问题不是 5G 信号弱，也不是 IPv6-only、TUN fd 或 `pdp_ip0` 绑定失败，而是 iOS Packet Tunnel 启动阶段形成了 DNS bootstrap circular dependency：

```text
系统 DNS 被 Packet Tunnel 捕获
        ↓
DNS 规则要求经 proxy 出站
        ↓
proxy 节点地址仍是域名
        ↓
连接 proxy 前必须先解析该域名
        ↓
解析请求又回到尚未建立的 proxy
```

Wi-Fi 正常是 DNS 缓存较热时的偶然成功，5G 异常是冷启动时稳定暴露死锁。修复后，iOS 在启动 Packet Tunnel 之前解析并固定节点地址，Xray 使用字面量 IP 建连，同时把该 IP 加入 `/32` 排除路由，避免 bootstrap 流量重新进入 TUN。

最终真机 5G 证据：

- `tky-proxy.svc.plus` 固定为 `43.207.194.92`。
- egress 为 `pdp_ip0`，地址族为 `v4=1 v6=3`。
- Xray 持续记录 `tcp:43.207.194.92:443`，TLS SNI/HTTP Host 仍为 `tky-proxy.svc.plus`。
- Packet Tunnel 配置包含 `43.207.194.92/32` 排除路由。
- 成功会话中没有 `no such host`、`仍按域名连接` 或 `No route to host`。
- iOS Release 构建、代码测试、macOS Desktop Release 构建均通过。

## 2. 初始现象与范围

用户观察到的基线：

| 平台/网络 | 现象 |
|---|---|
| iOS App + Wi-Fi | 正常 |
| iOS App + 5G | VPN UI 可能显示连接，但无有效数据流量，探测失败 |
| macOS Desktop + Wi-Fi | 正常 |

典型失败提示：

```text
隧道已连接但出站不可用，19.7s 内 10 次探测均无法建立连接
（弱网或节点不可达）: 8.8.8.8:443
SocketException: Connection failed
(OS Error: No route to host, errno = 65)
```

这个提示容易把问题误判为弱网。实际情况是失败发生在域名解析阶段，连接甚至没有进入正常 TCP/TLS 建连流程。

## 3. 根因定位过程

### 3.1 打开 Packet Tunnel 引擎错误日志

仅依赖 Flutter/App 日志时只能看到 `SocketException`，无法区分 DNS、路由、TLS 或远端拒绝。为此保留并使用了以下诊断能力：

- App 日志持久化到 `Library/Caches/logs/app.log`。
- Xray 引擎错误日志写入 App Group 的 `logs/xray-tunnel.log`。
- Packet Tunnel 启动时记录 egress 地址族到 `packet_tunnel_egress_info`。
- 记录 `packet_tunnel_started_at`、`packet_tunnel_last_error` 和 metrics snapshot。

关键 Xray 日志模式：

```text
proxy/tun: processing from udp:10.0.0.2:* to udp:1.1.1.1:53
app/dispatcher: taking detour [proxy] for [udp:1.1.1.1:53]
transport/internet/splithttp: XHTTP is dialing to tcp:tky-proxy.svc.plus:443
dial tcp: lookup tky-proxy.svc.plus: no such host
```

单次失败会话出现约 131 次 `no such host`，成功出站次数为 0，TUN 上下行均为 0 B/s。

### 3.2 排除其他假设

| 假设 | 结论 | 证据 |
|---|---|---|
| 5G 信号弱/偶发丢包 | 排除 | 失败是立即返回的 `EHOSTUNREACH`，不是连接超时；重复错误高度一致 |
| 运营商 IPv6-only | 排除 | `pdp_ip0: v4=1 v6=3`，链路同时具备 IPv4 |
| Packet Tunnel 没有真正启动 | 排除 | 引擎成功启动并创建 TUN，失败发生在出站 bootstrap |
| App 探测误报 | 排除 | TUN 上下行均为 0 B/s，与引擎 0 成功 dial 一致 |
| `pdp_ip0` 绑定导致出站失败 | 非根因 | 引擎在名字解析阶段就失败，尚未进入 socket dial |

### 3.3 为什么 Wi-Fi 能工作

Wi-Fi 场景更容易拥有已缓存的节点域名解析结果，首次出站可以直接复用缓存；5G 切换或全新安装后缓存为空，死锁立即暴露。因此“Wi-Fi 正常、5G 异常”不是两个独立问题，而是同一 bootstrap 缺陷受缓存状态影响的表现。

## 4. 期间发现的构建误判

第一次真机复验仍看到旧日志：

```text
出站服务器域名解析失败，仍按域名连接
```

检查后发现不是新代码失效，而是安装了旧 App 包：

- `xcodebuild` 的实际产物位于 Xcode DerivedData。
- 安装命令却使用了项目中旧的 `build/ios/Release-iphoneos/Runner.app`。
- 旧包时间早于新构建，导致真机仍执行旧逻辑。

处理方式：

1. 将旧的项目 iOS build 目录和旧 DerivedData 移入 macOS Trash，保留可恢复性。
2. 使用显式 `-derivedDataPath` 重新构建。
3. 对新包执行 `codesign --verify --deep --strict`。
4. 删除 iOS App 后重新安装，确保 SharedPreferences、App Group 和缓存均为全新状态。

这一步是本次 Debug 的重要经验：真机验证必须同时核对源代码 commit、App 包时间、安装路径和包内字符串，不能只看 UI。

## 5. 修复方案

### 5.1 iOS 节点地址预解析与固定

涉及：

- `lib/services/tunnel_endpoint_resolver.dart`
- `lib/utils/native_bridge.dart`
- `lib/services/vpn_config_service.dart`
- `ios/PacketTunnel/PacketTunnelProvider.swift`

处理顺序：

1. Packet Tunnel 启动前，先使用系统 resolver 解析节点域名。
2. iOS 在系统 resolver 失败时，使用字面量 IP UDP DNS 和字面量 IP DoH JSON 作为回退。
3. 将节点 outbound 的 `address` 替换为解析出的 IPv4 字面量。
4. 保留 `serverName` 和 XHTTP `host` 为原始域名，确保 TLS SNI、证书验证和虚拟主机行为不变。
5. 将节点 IP 写入运行时配置副本，不修改用户保存的 canonical 节点文件。
6. 将节点 IP 加入 Packet Tunnel 的 `43.207.194.92/32` excluded route。
7. 如果 iOS 解析最终失败，取消本次 VPN 启动，禁止留下一个仍按域名连接的半成品隧道。
8. 启动前等待旧 Packet Tunnel 进入 disconnected；最长等待 35 秒，避免旧会话仍捕获系统 DNS 时开始新一轮解析。

### 5.2 DNS 配置项清理

用户确认 macOS/Desktop 仍需要基础 DNS 设置，因此没有删除桌面端的基础 DNS能力，而是做了职责收敛：

- “直连 DNS” 重命名为“基础 DNS”（英文 `Base DNS`），明确它是本地/直连域名的明文系统 DNS 来源。
- 删除“服务器域名直连解析”设置；节点地址已经在启动前固定，该开关会造成重复且容易误导。
- iOS 隐藏并强制使用隧道 DNS 代理策略，避免 iOS 上暴露不能改变 bootstrap 拓扑的旧开关。
- macOS/Desktop 保留原有“隧道 DNS 走代理”能力和用户偏好。
- 代理侧 DoH resolver 改为内置 IP 字面量 Cloudflare/Google，避免代理 resolver 自己再引入域名 bootstrap。
- schema v4 清理已退休的服务器域名解析偏好；iOS 使用独立 `iosDnsSchemaVersion` 清理 iOS 专属旧偏好，不影响桌面迁移。
- 删除 Darwin 本地 DNS 捕获的死分支、无调用的 DNS control-plane 转发 getter 和过期嗅探路径。

### 5.3 Desktop 行为边界

本次修复明确限定 iOS cellular bootstrap 问题：

- macOS/Desktop 不使用 iOS 专属 UDP/DoH endpoint fallback。
- macOS/Desktop 保留原有 DNS 设置和 tunnel DNS toggle。
- macOS Desktop 仅做小步清理，不改变当前已正常的网络行为。

## 6. OneXray 对比结论

分析目录：`/Users/shenlan/workspaces/OneXray`。

OneXray 的可借鉴点：

- `PacketTunnelProvider` 使用字面量 DNS 地址配置 `NEDNSSettings`/`NEDNSOverTLSSettings`。
- Xray profile 将内置 DNS、代理 DNS 查询入口和 DNS outbound 分开。
- Packet Tunnel 通过 embedded runtime request 向扩展传递配置，而不是依赖一个容易失效的外部路径。

OneXray 没有解决本项目这一特定问题的部分：

- 不会自动解析并固定代理节点域名。
- 没有为代理节点 IP 添加 `/32` excluded route。
- 因此不能直接复制其 DNS 架构来解决 XConnect 的 5G bootstrap deadlock。

最终保留的是“字面量 bootstrap + 运行时配置”的思想，不复制 OneXray 的完整 DNS 拓扑。

## 7. 真机全新安装与 5G 复验

### 7.1 安装过程

1. 删除 iOS App。
2. 全新安装显式 DerivedData 构建出的 Release 包。
3. 关闭 Wi-Fi，确认状态栏为 5G。
4. 删除默认节点 `jp-xhttp.svc.plus`。
5. 选择 `tky-proxy.svc.plus`。
6. 锁屏并启动 VPN，保持 Tky 会话运行。

### 7.2 成功日志

App 日志：

```text
2026-08-14T19:26:20.034143 [info] [tunnel] 出站服务器已固定: tky-proxy.svc.plus -> 43.207.194.92
2026-08-14T19:26:30.645321 [info] [tunnel] 出站服务器已固定: tky-proxy.svc.plus -> 43.207.194.92
2026-08-14T19:26:31.702305 [info] [tunnel] TUN 模式启动成功 (tky-proxy.svc.plus)
2026-08-14T19:26:32.686908 [info] [tunnel] 外网可达 (1次探测, 1.0s)
```

Xray 日志：

```text
XHTTP is dialing to tcp:43.207.194.92:443, host tky-proxy.svc.plus
proxy/vless/outbound: tunneling request to udp:1.1.1.1:53 via 43.207.194.92:443
proxy/vless/outbound: tunneling request to tcp:104.17.112.106:443 via 43.207.194.92:443
```

成功会话持续产生真实出站请求；抓取到的统计包含至少 127 次固定 IP XHTTP dial 和 127 次经固定 IP 的代理请求，后续日志仍继续增长。

### 7.3 Packet Tunnel 运行配置

```text
interface: pdp_ip0
families: pdp_ip0: v4=1 v6=3
configPath: .../node-tky-config.runtime.json
ipv4ExcludedRoutes:
  destinationAddress: 43.207.194.92
  subnetMask: 255.255.255.255
```

运行时 JSON 中同时存在：

```json
{
  "address": "43.207.194.92",
  "port": 443,
  "serverName": "tky-proxy.svc.plus",
  "host": "tky-proxy.svc.plus"
}
```

这证明“底层 TCP 走 IP、TLS/HTTP 仍使用域名身份”的设计在实际节点上生效。

### 7.4 失败路径也符合预期

全新安装后默认节点 `jp-xhttp.svc.plus` 的首次解析失败记录为：

```text
出站服务器域名解析失败，取消 VPN 启动: jp-xhttp.svc.plus
保存失败: 无法在启动 VPN 前解析节点地址: jp-xhttp.svc.plus
```

这是修复后的 fail-closed 行为，不再退回“按域名启动”。随后选择 Tky 后成功，说明失败节点不会污染成功节点的 bootstrap 状态。

## 8. 压力与稳定性验证

仓库已有正式脚本：`scripts/ios_packet_tunnel_soak.sh`，文档为 `Runbook/iOS-Packet-Tunnel-Soak.md`。它采样：

- Packet Tunnel RSS、CPU、上下行吞吐
- Go heap in use、heap idle、heap released、runtime Sys
- GC 次数、goroutine 数
- `packet_tunnel_started_at` 是否变化
- `packet_tunnel_last_error`

本次按正式脚本启动了 2 分钟/10 秒间隔 soak。由于随后用户要求提交 PR 和发布 tag，实际采样在约 52 秒、6 个样本时中止；因此它是稳定性冒烟证据，不应冒充完整 2 分钟长压结论。

报告结果：

```text
samples=6  span=52s  final_uptime=434s
restarts=0  error_samples=0

process RSS       53.0 -> 53.1 MB
go runtime Sys    21.1 MB stable
go heap in use    5.6 -> 5.7 MB
cpu percent       0.1% -> 1.6%
goroutines        30 -> 39
GC cycles         63
RSS drift         +0.1 MB
VERDICT            no session restart and no reported error
```

脚本采样时上下行吞吐为 0 B/s，说明该段时间没有足够持续的用户流量，不能据此证明高吞吐下的内存稳定性；不过此前同一 5G 会话的 Xray 日志已证明固定 IP 出站请求持续发生。后续如果需要正式长压，应在设备侧持续刷视频、测速或产生其他真实流量，并完整运行 120 分钟脚本。

## 9. 自动化与构建验证

### 9.1 Flutter/Dart

```text
flutter analyze lib test
No issues found!

flutter test
All tests passed!  (103 tests)
```

覆盖重点：

- endpoint domain → IPv4 literal 替换
- explicit IP 不被改写
- DNS schema/migration
- desktop tunnel DNS 保留
- QUIC/TUN 路由顺序
- data-plane probe 的超时、退避、挂起和 DNS fallback

### 9.2 iOS Release

使用显式 DerivedData 路径执行：

```bash
xcodebuild -quiet \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -sdk iphoneos \
  -destination 'id=00008140-000E75903EF2801C' \
  -derivedDataPath build/ios-device \
  -allowProvisioningUpdates build
```

结果：

- `Runner.app` 生成成功。
- `codesign --verify --deep --strict` 通过。
- 新包包含 `Base DNS`、`iosDnsSchemaVersion` 和 Packet Tunnel settle 等新逻辑字符串。
- 已安装到真实 iPhone 并完成 5G 复验。

构建中仍有既有非阻塞 warning：LaunchImage 资源缺失、Swift switch 未覆盖 `.internalError`、`mobile_scanner` Objective-C ownership warning。

### 9.3 macOS Desktop Release

```bash
flutter build macos --release
```

结果：

- [xconnect.app](../build/macos/Build/Products/Release/xconnect.app) 构建成功。
- Universal Mach-O：`arm64` + `x86_64`。
- Bundle ID：`plus.svc.xconnect`。
- 版本：`1.0.0 (1)`。
- 包大小约 90 MB。
- `codesign --verify --deep --strict` 通过。

仅出现已有的 CocoaPods/Swift Package 迁移提示，不影响构建结果。

## 10. 发布记录

1. PR #50 已合并，提供最初的 endpoint pinning 修复基础。
2. 本次 DNS UI/策略清理和 iOS 加固提交为 `621618a`。
3. 创建 PR #51，并通过 gitleaks 安全检查。
4. PR #51 合并到 `main`，合并 commit 为 `27a312d`。
5. 经过 tag 命名调整，最终发布 tag 为 `v2026.08.14-1938`。
6. 错误的中间 tag `v2026.08.14` 和 `v-26-08-14-19-36` 已删除，避免生成错误命名的发布物。
7. 最终 tag 对应的 GitHub Actions 发布构建已触发。

当前本地工作区只保留用户自己的未跟踪 `.claude/`，未将其纳入提交。

## 11. 复验命令与证据位置

真机 App 日志：

```bash
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer \
  --domain-identifier plus.svc.xconnect \
  --source Library/Caches/logs/app.log \
  --destination ./app.log
```

真机 Xray 日志：

```bash
xcrun devicectl device copy from --device <UDID> \
  --domain-type appGroupDataContainer \
  --domain-identifier group.plus.svc.xconnect \
  --source logs/xray-tunnel.log \
  --destination ./xray.log
```

Packet Tunnel 配置快照：

```bash
xcrun devicectl device copy from --device <UDID> \
  --domain-type appGroupDataContainer \
  --domain-identifier group.plus.svc.xconnect \
  --source Library/Preferences/group.plus.svc.xconnect.plist \
  --destination ./group.plist
plutil -p ./group.plist
```

本次临时证据目录：

- `/tmp/xconnect-5g-final.mEOlZg`
- `/tmp/xconnect-5g-final-latest.rj7kUZ`
- `/tmp/xconnect-ios-soak-official`

这些目录属于本机临时调试产物，不是发布输入；若需要长期归档，应将脱敏后的日志和 soak CSV 单独保存，避免把设备日志中的节点、域名或运行时信息直接提交到仓库。

## 12. 遗留事项

- 本次 soak 只有约 52 秒且吞吐为 0，正式长压仍建议在真实持续流量下运行 120 分钟。
- iOS 首次默认节点失败时出现过一次旧 Packet Tunnel 未在 35 秒内 settle 的警告；Tky 成功启动不受影响，但该启动清理延迟值得后续单独优化。
- macOS 工程仍提示 CocoaPods 与 Swift Package 混用，属于构建维护事项，不是本次 DNS 问题。
- 构建 warning 中的 LaunchImage、Swift exhaustive switch 和 mobile_scanner warning 尚未纳入本次功能修复范围。
- 代理 IP 变化时需要重新启动连接才能重新解析和生成新的 runtime config；当前实现没有后台 DNS TTL refresh。
