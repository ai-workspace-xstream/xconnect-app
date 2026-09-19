# R0 / M0 spike：macOS App Sandbox 实测（2026-09-19）

- 关联：#89（M0）、#88（R0）；设计见 [`network-self-repair.md`](../design/network-self-repair.md) §4、[`macos-distribution-channels.md`](../design/macos-distribution-channels.md)
- 探针代码在分支 `spike/macos-sandbox-r0`（`lib/spike/sandbox_probe.dart`、`AppDelegate.swift` 中的 `SandboxProbe`），**不合并**
- 环境：macOS **27.0**（26A428）、Xcode **27.0**（27A266a）、Flutter 3.41.4、Apple Silicon

## 1. 方法

- 同一份 arm64 release 构建，用 ad-hoc 签名分别打成两个版本：
  - **沙盒版**：entitlements 为 `app-sandbox` + `network.client` + `network.server`
  - **对照版**：不开沙盒
- 两个版本使用独立的 Bundle ID（`plus.svc.xconnect.sandboxspike` / `.nosandboxspike`），各自得到全新的容器，不碰 `plus.svc.xconnect` 的现有数据。
- App 画出第一帧后执行 19 项只读检查，把结果以 JSON 形式输出到 stdout，然后退出。
- 写操作只有一项：在 `~/Library/LaunchAgents` 写入一个临时文件并立即删除。**没有测试任何会改动系统网络配置的写操作。**

### 本次无法验证的内容

- 机器上没有签名身份，所以构建不能携带 NE / App Group 这类受限权限，App 也就无法启用隧道。
- 因此 **S1（重连隧道能否清掉 DNS 缓存）仍然无法验证**，需要等签名环境就绪。

## 2. 结果

| 检查 | 对照版 | 沙盒版 | 说明 |
|---|---|---|---|
| 启动并画出第一帧 | ✓ | ✓ | 沙盒版启动过程中没有新增错误日志 |
| `HOME` | `/Users/shenlan` | `…/Containers/<id>/Data` | 沙盒生效 |
| P1–P3 `scutil --dns / --nc list / --proxy` | ✓ | ✓ | **沙盒内起子进程做只读查询是可行的**，能列出其他 VPN 配置（C1/C4） |
| P4–P5 `networksetup -listallnetworkservices / -getdnsservers` | ✓ | ✓ | 只读可行 |
| P6–P7 `id -u`、`launchctl print gui/<uid>` | ✓ | ✓ | 只读可行 |
| P8 `bash -c` | ✓ | ✓ | |
| F1 读取 `/etc/hosts`（D4） | ✓ | ✓ | |
| F2 列出 `/Library/LaunchDaemons`（C3，孤儿助手检测） | ✓ | ✓ | |
| **F3 写入 `~/Library/LaunchAgents`** | ✓ | **✗** `PathAccessException` | 基于 LaunchAgent 的节点服务在沙盒下**不可用**（与 §4.4 的推断一致） |
| F4 读取旧版日志 `~/Library/Caches/plus.svc.xconnect/…` | ✓ | ✓ | 超出预期。可能与 ad-hoc 签名带有 `get-task-allow` 有关，**MAS 签名后需要复测** |
| F5 写入容器内的 Application Support | ✓ | ✓ | |
| N1 TCP 连接 1.1.1.1:443 | ✓ 0ms | ✓ 0ms | **测量无效**，见 §3.1 |
| N2 监听 127.0.0.1 | ✓ | ✓ | 依赖 `network.server` 权限 |
| N3 HTTPS HEAD github.com | ✗ 超时 | ✗ 超时 | 两个版本都失败，是网络环境问题，与沙盒无关 |
| N4 DNS 解析节点域名 | ✓ | ✓ | |
| S2 SystemConfiguration（全局 DNS、全局 IPv4、代理、各服务的 DNS 设置）、`sysctl net.inet.tcp.stats` | ✓ | ✓ | **S2 通过**：沙盒内通过 API 只读访问可行 |

### 与设计推断的差异

`network-self-repair.md` §4.4 原先推断「权限向导中调用的 `launchctl` / `networksetup` / `scutil` 大多会失败」。实测结果是：**在 macOS 27 上，这些只读调用在沙盒内都能正常工作。**

- 仍然被阻止的是**写**。已确认 LaunchAgents 不能写；系统网络配置的写操作这次没有测，这是有意为之。
- 更关键的是审核层面：App Review 2.4.5 要求 MAS App 不得申请提权，所以即使技术上能执行，**需要管理员权限的写操作在 MAS 版本中仍然只能走 `guided` 模式**，这个结论不变。

## 3. 额外发现（影响设计）

### 3.1 🔴 另一个 TUN 在运行时，TCP 连接探测会得到假结果

- 本机 OneXray 的 TUN（`utun4`）会在本地直接完成**所有** TCP 握手：
  - `1.1.1.1`、`10.255.255.1`、`192.0.2.1`（文档保留地址，永远不应该有应答）全部在 **0ms** 内「连接成功」；
  - 这些连接都走 `utun4`。
- 把 socket 的源地址绑定到物理网卡（en0 的地址 `192.168.0.107`）之后：
  - `192.0.2.1` 正确超时；
  - 节点 `35.79.83.48:443` 在 **86ms** 内连接成功，这是真实的 RTT；
  - `1.1.1.1:443` 在物理路径上超时，说明这个地址在当前网络下被阻断。
- **对自诊断设计（#86）的影响**：
  - S1 和 S2 探测**必须绑定物理网卡的源地址**，否则只要有 TUN（包括我们自己的隧道）在运行，测出来的都是 0ms / 0% 丢包的假数据。
  - 可以向 `192.0.2.1`（RFC 5737 保留地址）发一个「哨兵」连接，作为廉价的冲突检测：如果它能连上，就说明本机有 TUN 在本地应答（C1）。
- 相关改动已写入 `network-self-diagnosis.md` §2.2。
- 顺带发现：DoH 配置 `https://1.1.1.1/dns-query` 在当前网络的物理路径上走不通，只能经隧道访问。

### 3.2 🔴 Xcode 27 的 `lipo` 导致 Flutter 3.41.4 无法构建 macOS universal 包

- `lipo -verify_arch arm64 x86_64 <file>` 在 Xcode 27 上报错 `requires exactly one input file`，只指定一个架构时正常。
- Flutter 3.41.4 的 `release_unpack_macos` 步骤会用两个架构调用它，结果报出自相矛盾的错误：「does not contain architectures arm64 x86_64」。
- 临时办法：构建时加 `FLUTTER_XCODE_ARCHS=arm64`（只出 arm64）。
- **CI runner 升级到 Xcode 27 后，现有 CI 的 macOS 构建会直接失败**，需要单独跟进：升级 Flutter，或者分架构构建后再用 `lipo -create` 合并。

### 3.3 🟡 签名不同的沙盒 App 复用同一个容器时，启动会卡住

- 用 ad-hoc 签名的沙盒版以 `plus.svc.xconnect` 身份启动时，进程卡在 `_libsecinit_appsandbox` 的 XPC 调用上，App 自己的代码一行都没有执行。
- 原因是这个容器此前由另一个签名创建过。换成全新的 Bundle ID 后问题消失。
- **对双渠道的影响**：同一 Bundle ID 的不同签名构建（开发版、MAS 版、直装版）在同一台机器上会争用同一个容器，会被系统拦截或者弹出授权框。
- 这进一步支持 `macos-distribution-channels.md` Q1 的建议：**直装版使用独立的 Bundle ID**。
- 开发过程中也要为沙盒调试构建使用单独的 Bundle ID。

### 3.4 本机只读取证：App 容器受保护

从 App 外部（包括终端）读取其他 App 的容器会返回 `Operation not permitted`（App Data 保护）。这意味着：

- 沙盒版 App 的日志将无法再从 `~/Library/Caches/...` 直接读到；
- 「导出日志」必须由 App 自己完成，并通过用户选择的位置（`NSSavePanel`）写出；
- 诊断记录和修复记录也一样。

## 4. 结论与后续

| 项 | 状态 |
|---|---|
| S2（沙盒内读取系统网络状态） | ✓ 通过：SystemConfiguration API 和只读子进程都可行 |
| S3（沙盒对现有功能的影响） | 部分完成：LaunchAgent ✗；只读查询 ✓；系统网络配置的写操作未测，也不计划在 MAS 版本中使用 |
| S1（重连隧道能否清缓存） | ⛔ 阻塞：需要签名环境 |
| M0 ①（现有直装 DMG 在干净机器上能否启用隧道） | ⛔ 阻塞：需要签名环境，以及一台干净的 Mac |
| 新增：自诊断探测必须绑定物理网卡 | 已写入设计，需要在 #86 PR2 中实现，并配测试 |
| 新增：Xcode 27 + Flutter 3.41.4 无法构建 universal 包 | 需要另开 issue |
