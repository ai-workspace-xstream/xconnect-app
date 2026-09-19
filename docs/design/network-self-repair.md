# 网络自修复（Network Self-Repair）设计

- 关联：[`network-self-diagnosis.md`](./network-self-diagnosis.md)（诊断负责发现问题，本文负责修复）、issue #86
- 复用：PR #79 的 `scripts/dns-flush.sh` / `dns-check.sh` / `dns-cache.ps1`；PR1 的 `SettingsTabId` / `SettingsTabRequest` 跳转机制
- 平台：macOS / Windows / Linux / iOS / Android
- 状态：设计稿 v1，待评审

---

## 0. 起因：2026-09-19 本机故障复盘

用户反馈：当天网络异常，怀疑与网易 UU 加速器的网络配置冲突有关。以下是在出问题的这台 Mac 上只读取证的结果。

### 0.1 证据

| # | 现象 | 来源 |
|---|---|---|
| E1 | 07:02:24 解析 `jp-xconnect.svc.plus` 失败；07:02:25 保存 VPN 配置失败：`NEVPNErrorDomain code=5 permission denied` | XConnect `~/Library/Caches/plus.svc.xconnect/logs/app.log` |
| E2 | **同一个 code=5 报错在 08-31、09-03、09-13、09-19 都出现过** | 同上 |
| E3 | 本机没有任何代码签名身份（`security find-identity` 为 0），Xcode 也没有登录 Apple ID | `security` / Xcode 偏好设置 |
| E4 | UU 的 root 级助手 `com.netease.uumac.helper` 仍安装在 `/Library/LaunchDaemons` 和 `/Library/PrivilegedHelperTools`（`KeepAlive` + `RunAtLoad`），二进制在 **07:16** 被写入；但 `/Applications` 里已经没有 UU 主程序 | 文件系统、`codesign`（Team `PU9BNSBJW7`） |
| E5 | 另一个 VPN（OneXray，`net.yuandev.onexray`）处于已连接状态，占用了默认路由（`utun4`）和首选 DNS 解析器；本机共有 5 个 utun 接口 | `scutil --nc list`、`netstat -rn`、`scutil --dns` |
| E6 | Wi‑Fi 网络服务上被手动写死了 DNS `1.1.1.1 8.8.8.8`。XConnect 代码里没有写系统 DNS 的逻辑，这个设置来自别处 | `networksetup -getdnsservers`；在仓库中 grep 确认 |
| E7 | 当前 en0 的网关是 `172.20.10.1`，也就是 iPhone 个人热点 | `netstat -rn` |
| E8 | 现在节点域名已能正常解析（系统解析与直连 1.1.1.1 的结果一致） | `dscacheutil`、`dig` |

### 0.2 结论（按证据强弱）

1. **XConnect 当天连不上，直接原因不是 UU。**
   - 失败点是保存 VPN 配置被拒（E1）。同样的报错从 08-31 起反复出现（E2），早于当天任何 UU 活动。
   - 本机没有签名身份（E3），本地构建的包缺少有效的 Network Extension 签名，系统拒绝写入 VPN 配置。**这属于构建和签名问题，在 App 内无法自修复**，只能明确告诉用户。
2. **DNS 解析失败（E1 前半段）是暂时性的，最可能的原因是多个隧道同时抢 DNS。**
   - OneXray 当时可能在接管全局 DNS（E5）。
   - 网络本身是手机热点（E7），而 Wi‑Fi 上又写死了公共 DNS（E6），这两者叠加都会让结果不稳定。
   - 现在已经恢复正常（E8）。
3. **UU：有风险，但本次证据不足以定罪。**
   - 它的 root 助手在主程序不存在的情况下仍常驻（E4），属于典型的「卸载不干净的系统级残留」。这类残留有能力改路由、DNS 和防火墙。
   - 但它的写入时间 07:16 晚于故障时间 07:02，而且在无 sudo 的条件下查不到它当天的日志。
   - 要确认，需要用户手动执行 `sudo launchctl print system/com.netease.uumac.helper`，并用 `sudo log show` 查看 06:30–07:30 的日志。
4. **这次故障暴露的问题**：同一台机器上同时存在多个会接管路由或 DNS 的组件（XConnect、OneXray、UU 残留、手动 DNS）。用户看到的症状都是「网不通」，却无从判断是哪一个造成的。自修复页首先要解决的，就是**把这些冲突源列出来**。

---

## 1. 可能导致冲突的场景（全平台清单）

各场景都用编号标注，后文的检测项和修复项会引用这些编号。

### 1.1 多个加速器 / VPN 并存（本次的主线）

| 编号 | 场景 | 典型来源 | 表现 |
|---|---|---|---|
| C1 | 另一个 VPN 或 TUN 接管默认路由（`0/1` 和 `128/1`，或 `default` 指向 utun/wintun） | UU、迅游、雷神、OneXray、Clash Verge 的 TUN 模式、Surge 增强模式、公司 VPN | 我们的流量被别人的隧道截走，或两个隧道互相套娃 |
| C2 | 另一个组件把 DNS 解析器全局接管（`matchDomains [""]`） | 同上 | 节点域名被解析到错误地址或超时（本次 E1、E5） |
| C3 | 卸载后仍残留 root 级助手、LaunchDaemon、系统服务或驱动，持续改写网络 | UU 的 helper（本次 E4）；Windows 上残留的 LSP、WFP 驱动、TAP 网卡 | 「没开任何加速器也不通」 |
| C4 | macOS / iOS 同一时刻只能有一个个人 VPN 处于连接状态 | 系统机制 | 连接 XConnect 会断开别人的 VPN，反之亦然；用户误以为是故障 |
| C5 | Android 上其他 App 设置了「始终开启 VPN」或「屏蔽未使用 VPN 的连接」 | 系统设置 | `VpnService.prepare()` 永远返回授权 Intent，或流量被系统直接拦截 |

### 1.2 DNS

| 编号 | 场景 | 表现 |
|---|---|---|
| D1 | 系统负缓存：记录变更后，旧的 NXDOMAIN 还留在缓存里（PR #79 的场景） | `Could not resolve hostname` |
| D2 | 网卡上手动写死了 DNS，在当前网络不可达或被污染（本次 E6；例如国内访问 8.8.8.8 不稳定） | 超时；换网络后才出问题 |
| D3 | 网卡上手动 DNS 导致强制门户（酒店、机场）无法弹出登录页，公司内网域名也解析不了 | 连上 Wi‑Fi 却没网 |
| D4 | `/etc/hosts`（或 Windows 的 `hosts` 文件）被加速器写入覆盖条目 | 特定域名始终指向固定 IP |
| D5 | Windows 残留 NRPT 规则，或已断开的 VPN 网卡上还残留 DNS 配置 | 部分域名走错解析器 |
| D6 | Linux：`/etc/resolv.conf` 没有指向 systemd-resolved 的 stub，或 NetworkManager 与 resolved 互相覆盖 | 解析时好时坏 |
| D7 | Android「私人 DNS」设为严格模式，但主机不可达 | 整机无法解析 |
| D8 | IPv6 泄漏或不通：隧道只接管了 IPv4，AAAA 查询走了别的解析器（本机解析器里有 `2001:4860:4860::8888` 经 utun4） | 双栈站点慢或失败 |

### 1.3 隧道和系统代理

| 编号 | 场景 | 表现 |
|---|---|---|
| T1 | App 崩溃或被强杀后，系统代理仍指向 `127.0.0.1:1080`。我们在 macOS 上会给**所有**网络服务设置 SOCKS 代理（`NativeBridge+SystemProxy.swift`） | 浏览器全部失败，其他 App 正常 |
| T2 | 残留的 utun / wintun / tun 设备和路由（本机有 5 个 utun，MTU 从 1000 到 2000 不等） | 路由黑洞、MTU 问题导致大包丢失 |
| T3 | 我们自己的 VPN 配置损坏或过期（`NEVPNError` 为 configurationStale 或 invalid；Android 服务状态异常） | 点「连接」没有反应，或立即断开 |
| T4 | **签名或授权问题**：`code=5 permission denied`（本次 E1），或用户拒绝了「添加 VPN 配置」弹窗 | 每次都失败；**无法自修复，只能引导用户** |
| T5 | 网络切换（Wi‑Fi、热点、蜂窝）后隧道没有重连；iOS 蜂窝网络 DNS 死锁（见 `docs/ios-cellular-dns-deadlock-*.md`） | 切换网络后断流 |
| T6 | 安全软件拦截（Little Snitch、LuLu、Windows Defender 防火墙、360 等） | 扩展进程被阻止联网 |
| T7 | Windows：残留的 Winsock LSP（老式加速器常见） | 所有 TCP 异常，需要 `netsh winsock reset` 并重启 |
| T8 | Linux：nftables / iptables 标记、`ip rule` 策略路由残留 | 部分流量绕开隧道或进入黑洞 |

### 1.4 其他

| 编号 | 场景 | 表现 |
|---|---|---|
| O1 | 系统时间偏差 | TLS 握手失败 |
| O2 | MDM / 企业描述文件强制配置了 DNS 或代理 | 修复后很快被改回 |
| O3 | Android 电池优化杀掉了 VPN 服务 | 后台断连 |

---

## 2. 页面与入口

- 在设置页新增标签 `SettingsTabId.repair`，中文名「修复」，图标 `Icons.build_outlined`，放在「诊断」之后。
  沿用 PR1 的按 id 跳转机制：诊断结论里的「如何处理？」直接跳到这里，**并定位到对应的修复项**（`SettingsTabRequest` 增加可选字段 `anchor`）。
- 页面结构沿用设置页的 `SettingsGroup` + `SettingsRow`，风格与 `docs/design/ui-style-system.md` 一致，不另造组件体系。

从上到下：

1. **冲突检查**（打开页面时自动执行，**只读**）：把 §1 中能检测到的场景逐条列出。每条给出状态（正常 / 注意 / 冲突）、一句话说明和对应的修复按钮。
2. **一键修复**（按平台显示可用项，见 §3）：清理 DNS 缓存 / 修复 DNS / 修复隧道配置 / 关闭残留系统代理。
3. **需要你手动处理**：检测到了、但 App 不能也不应该替用户处理的问题。包括其他厂商的残留（C3，例如 UU helper）、签名问题（T4）、企业配置（O2）、Android 系统设置（C5、D7），每项给出具体路径或命令。
4. **修复记录**：每次修复前后的系统快照（可复制），以及「撤销上次修复」。

---

## 3. 修复项 × 平台矩阵

✓ 表示 App 内可执行；◐ 表示需要系统授权弹窗（UAC 或 polkit），由系统弹出；⚑ 表示引导用户操作（打开系统设置，或给出可复制的命令）；— 表示不适用。

> **2026-09-19 已决定：macOS 上架 Mac App Store，必须开启 App Sandbox。**
> 因此下表中 macOS 行的所有 ◐ 都改为 **⚑ 引导执行**。macOS 上 App 内能做的只剩三类：
> - 操作 App **自己的** NE 配置；
> - 操作 App **自己的**隧道 DNS 和代理设置（`NEDNSSettings` / `NEProxySettings`）；
> - 清理 App **自己的**缓存。
>
> 执行模式的完整模型见 §4。

### 3.1 清理 DNS 缓存（D1）

| 平台 | 做法 | 权限 |
|---|---|---|
| macOS（MAS 沙盒） | 先在 App 内**重连自己的隧道**，DNS 配置变化可能让 mDNSResponder 清掉受影响的缓存（**待 spike S1 验证**）。仍无效时给出可复制的命令 `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`，由用户在终端里执行 | ✓ + ⚑ |
| Windows | `Clear-DnsClientCache`，再执行 `ipconfig /flushdns`（与 `dns-cache.ps1` 一致） | ◐ 通过 UAC 提权（在各 Windows 版本上是否必须提权，要在 PR 中验证） |
| Linux | 依次尝试 `resolvectl flush-caches`、`nscd -i hosts`、重载 dnsmasq | ◐ 通过 `pkexec` 走 polkit |
| iOS | 没有公开 API 可以清理系统缓存。改为清理 **App 自身**的缓存（已固定的节点 IP、DoH 结果）并重建隧道；然后引导用户开关一次飞行模式 | ✓ + ⚑ |
| Android | 同 iOS；另外引导检查「私人 DNS」 | ✓ + ⚑ |

### 3.2 修复 DNS（D2–D8）

| 平台 | 检测 | 修复 |
|---|---|---|
| macOS（MAS 沙盒） | 不再起子进程，改用 SystemConfiguration API 只读取 `State:/Network/Global/DNS` 和各网络服务的 DNS 设置（C2/D2/D3），**沙盒内能否读取待 spike S2 验证**；`/etc/hosts` 能否读取同样待验证（D4） | 隧道连接期间，由我们的 `NEDNSSettings` 接管解析，本身就能绕开手动 DNS，这一步 ✓。要恢复网卡上的手动 DNS，走 ⚑：首选深链打开「系统设置 → 网络 → <服务> → 详细信息 → DNS」并给出步骤；备选给出命令 `networksetup -setdnsservers "<服务>" Empty`。App 在执行前记录原值，用户操作后 App 复查结果 |
| Windows | `Get-DnsClientServerAddress`、`Get-DnsClientNrptRule`、hosts 文件 | ◐ `Set-DnsClientServerAddress -ResetServerAddresses`（先备份）；NRPT 只提示 |
| Linux | `resolvectl status`，`/etc/resolv.conf` 的指向，NetworkManager 连接的 DNS 设置 | ◐ `resolvectl revert <网卡>`；`nmcli` 恢复自动 DNS（先备份） |
| iOS | 只能看到 App 自身隧道的 `NEDNSSettings` | ✓ 重建自身的 DNS 设置；⚑ 引导到「设置 → VPN 与设备管理」检查其他描述文件 |
| Android | `LinkProperties` 中的 DNS 和 `privateDnsServerName`（公开 API） | ⚑ 私人 DNS 只能引导到系统设置修改 |

### 3.3 修复隧道配置（T1–T5、C1、C4、C5）

| 平台 | 检测 | 修复 |
|---|---|---|
| macOS（MAS 沙盒） | 沙盒内看不到其他 App 的 VPN 配置（`NEVPNManager` 只返回自己的）。改为用 SystemConfiguration 读取主接口和默认路由的归属：主接口是 utun、而我们的隧道未连接，就判定为「另一个隧道在接管」（C1/C4，**待 spike S2 验证**）。系统代理用 `SCDynamicStoreCopyProxies` 读取（T1） | ✓ 删除并重建**自己的** `NETunnelProviderManager`（处理 T3）；T1 **在架构层面消除**：系统代理改由隧道的 `NEProxySettings` 下发，隧道断开时系统自动撤销（见 §4.3），不会再有残留。旧版本遗留的代理走 ⚑，引导到「系统设置 → 网络 → 代理」。其他 VPN 只提示「请先断开」 |
| Windows | `Get-NetAdapter` 找残留的 wintun / TAP 网卡；`route print` 找残留的 `0.0.0.0/1` 路由；WinHTTP / IE 代理设置 | ◐ 删除**我们创建的**路由和网卡、重启服务；⚑ Winsock 重置（T7）需要重启电脑，只给出指引并请用户确认 |
| Linux | 残留的 `tun*` 设备、`ip rule`、nft 表 | ◐ 删除**我们创建的**规则和设备、重启服务（沿用现有的 TUN 助手） |
| iOS | `NEVPNStatus` 和我们自己的配置状态 | ✓ 删除并重建自己的配置；⚑ 签名或授权问题（T4） |
| Android | `VpnService.prepare()` 的返回值（C5）；服务是否存活（O3） | ✓ 重启服务；⚑ 引导到「始终开启的 VPN」设置和电池优化设置 |

### 3.4 不做的事（红线）

1. **不动其他厂商的东西**：不结束 UU 等其他 App 的进程，不删除它们的 helper 或 LaunchDaemon，不修改或删除它们的 VPN 配置。只检测、只提示，并给出官方卸载方式。越界操作既有法律和商店审核风险，也可能搞坏用户的其他软件。
2. **不收集用户的管理员密码**：
   - Windows / Linux 提权一律通过系统自带的对话框（UAC、polkit）完成。
   - macOS（MAS 沙盒）上 App 不提权，需要管理员权限的操作只走 `guided` 模式。
   现有的 `NativeBridge.resetXrayAndConfig(String password)`（Windows / Linux）要求 App 接收 sudo 密码，**这是需要改掉的反模式**，放进 R6 处理。
3. **每项修复都有快照和撤销**：先记录原值，再执行修改，然后验证结果；验证失败时自动回滚。
4. **不在后台自动修复**：每次修复都由用户点击触发，并展示将要执行的命令。

---

## 4. 执行模式架构（macOS 上 MAS 之后）

### 4.1 决定

2026-09-19 已决定：**macOS 上架 Mac App Store**，所以 `Release.entitlements` 必须开启 `com.apple.security.app-sandbox`。

目前仓库里关于沙盒只有 `docs/publish-stores.md` 中的一句话，没有迁移方案。这个决定不只影响修复功能，App 中其他几项功能也会受影响，见 §4.4。

### 4.2 三种执行模式：按能力分，不按操作系统分

每个修复项在运行时声明自己的执行模式，由 `DesktopPlatformCapabilities` 决定。这个类目前按操作系统区分，需要**增加一个「分发渠道」维度**：

```dart
enum RepairExecution {
  inAppPrivileged, // Windows(UAC) / Linux(polkit)：系统弹窗授权后，由 App 执行
  appScoped,       // 只动 App 自己的东西：NE 配置、隧道的 DNS/代理设置、App 内缓存（五个平台都有）
  guided,          // App 只负责检测和复查；执行交给用户（深链到系统设置，或可复制的命令）
}
```

| 平台 / 渠道 | 可用的模式 |
|---|---|
| macOS · Mac App Store（沙盒） | `appScoped` + `guided`，**不允许** `inAppPrivileged` |
| Windows / Linux | 三种都可用 |
| iOS / Android | `appScoped` + `guided` |

- **渠道由构建时指定**：通过 `--dart-define=XCONNECT_DISTRIBUTION=mas|direct` 传入。
- 运行时再用环境变量 `APP_SANDBOX_CONTAINER_ID` 复核：如果声明是 `direct`，但实际运行在沙盒里，就降级为 `guided`，并记录一条日志。
- 这样即使以后保留一个 Developer ID 直装版本，也不需要分叉代码。

**`guided` 模式的交互**（按优先级依次尝试，第一种可行就用它）：

1. **在 App 内绕过问题**：例如隧道连接期间由 `NEDNSSettings` 接管 DNS，用户根本不用去改网卡。
2. **深链打开系统设置对应页面**，并给出分步说明。
3. **可复制的命令**，作为最后手段：
   - 命令字符串来自白名单模板，网络服务名等变量必须经过 shell 转义；
   - 界面上注明「需要管理员密码，请在终端中执行」；
   - App **不会**替用户执行这些命令；
   - 用户执行完后点「我已执行，重新检查」，App 复查结果。

> **审核风险**：App Review 对「引导用户在终端执行 sudo 命令」的态度没有明确条款可依。所以第 3 种只放在「高级」折叠区里，默认展示前两种。第一次提审时要在审核备注中说明用途。

### 4.3 沙盒带来的一个好处：系统代理不会再残留

- 现在的系统代理模式：`NativeBridge+SystemProxy.swift` 通过 `/bin/bash` 调用 `networksetup`，给**所有**网络服务设置 SOCKS 代理。
- 在沙盒里，这条路**走不通**。
- 改为在 PacketTunnel 的 `NEPacketTunnelNetworkSettings` 中下发 `NEProxySettings`：代理只在隧道连接期间生效，隧道断开或 App 崩溃时由系统自动撤销。
- 这样 T1（残留代理）在 macOS 上**从架构层面就不会出现**，也就不需要对应的修复项。

### 4.4 沙盒对现有功能的影响（修复范围之外，已拆分到单独的 issue）

| 现有功能 | 位置 | 沙盒内 | 建议 |
|---|---|---|---|
| 系统代理（networksetup） | `macos/Runner/NativeBridge+SystemProxy.swift` | ✗ 不可用 | 改用 `NEProxySettings`（§4.3） |
| 权限向导中调用 `launchctl`、`networksetup`、`scutil`、`id`、`open` | `lib/services/permission_guide_service.dart`、`lib/widgets/permission_guide_dialog.dart` | 子进程会继承沙盒限制，大多数调用会失败 | 在 MAS 版本中重写权限向导，只保留 NE 授权引导 |
| 基于 LaunchAgent 的节点服务（`VpnNode.serviceName` 在 macOS 上是 LaunchAgent plist） | `lib/services/vpn_config_service.dart` | ✗ 不能写 `~/Library/LaunchAgents` | 「仅代理」模式改为在 NE 内或 App 进程内运行核心 |
| 下载或更新 Xray 核心（`GlobalState.xrayUpdating`） | `lib/utils/global_config.dart` | 违反审核指南 2.5.2（不得下载可执行代码） | 核心随 App 打包，跟随 App 版本一起更新 |
| 运行时 MCP 服务中的子进程 | `lib/services/mcp/runtime_mcp_service.dart` | 需要逐项验证 | MAS 版本默认关闭 |
| 开机自启（`SMAppService.mainApp`） | `macos/Runner/AppDelegate.swift:357` | ✓ 可用 | 不用改 |

以上判断都是**基于代码阅读的推断**，需要一次 spike 实测：开启沙盒构建后，逐项运行确认。

### 4.5 其他平台的合规约束

| 平台 | 约束 |
|---|---|
| iOS | 只能操作 App 自己的 NE 配置，矩阵中的 iOS 列已按此设计 |
| Android | 只能调用公开 API。读取 `LinkProperties` 需要的是 `ACCESS_NETWORK_STATE`，诊断功能已经申请 |
| Windows / Linux | 提权必须由用户主动触发，并且通过系统弹窗完成，符合 §3.4 |

### 4.6 需要先做的 spike

| 编号 | 要验证的问题 | 影响 |
|---|---|---|
| S1 | 重连我们自己的隧道后，mDNSResponder 是否会清掉目标域名的负缓存 | 结果决定 macOS 上的「清理 DNS 缓存」能否不依赖终端命令 |
| S2 | 沙盒里能否通过 SystemConfiguration 读取全局 DNS、各服务的手动 DNS、主接口、系统代理，以及 `/etc/hosts` | 结果决定 macOS 冲突扫描能覆盖多少场景 |
| S3 | 开启沙盒构建后，逐项运行 §4.4 中的现有功能 | 结果决定 MAS 迁移的实际工作量 |

---

## 5. 代码结构

```
lib/services/repair/
  conflict_scanner.dart       # 抽象接口 + 各平台实现，只读，输出 List<ConflictFinding>
  repair_action.dart          # 统一接口：snapshot() / apply() / verify() / rollback()
  actions/
    flush_dns_cache.dart      # 各平台实现，命令与 scripts/dns-flush.sh、dns-cache.ps1 对齐
    reset_manual_dns.dart
    rebuild_tunnel_profile.dart
    clear_stale_system_proxy.dart
  repair_execution.dart       # RepairExecution 枚举，以及根据平台能力和分发渠道选择执行模式
  privileged_runner.dart      # UAC / pkexec 的封装（仅 Windows / Linux），不接受密码参数
  guided_steps.dart           # 深链目标、分步说明、白名单命令模板和 shell 转义（纯函数）
  repair_journal.dart         # 快照与撤销记录（本地 JSON）
```

- 每个修复项实现 `supportedModes`，界面根据 `resolveExecution(action, capabilities)` 的结果渲染：「修复」按钮，或者「引导步骤 + 重新检查」按钮。
- `privileged_runner.dart` 在 macOS 上**不编译进包**，或者直接抛出异常，这一点由测试保证。

- 把命令执行抽象成可注入的 `typedef CommandRunner`，测试中使用 fixture 输出，不会真正改动系统（与 `tunnel_data_plane_probe.dart` 的注入方式一致）。
- 解析器（`scutil --dns`、`scutil --nc list`、`networksetup`、`Get-DnsClientServerAddress`、`resolvectl status` 的输出）全部写成纯函数，各配一份 fixture。**本次取证得到的真实输出**（E4–E6）直接用作 macOS 的 fixture。

---

## 6. TDD 任务拆分（接在诊断的 PR1–PR8 之后）

| PR | 内容 | 先写的失败测试 |
|---|---|---|
| R0 | spike S1–S3：开启沙盒构建，实测结果写回 §4.4 和 §4.6（只写文档，不合并代码） | — |
| R1 | 新增修复标签和入口：`SettingsTabId.repair`，`SettingsTabRequest.anchor`，诊断页「如何处理？」跳转到对应修复项 | anchor 能定位到对应修复项；目标标签被过滤掉时返回 null |
| R1b | 执行模式：`RepairExecution`、分发渠道 `--dart-define`、运行时沙盒复核、`guided_steps`（命令模板与转义） | MAS 渠道下永远不会得到 `inAppPrivileged`；声明 `direct` 但检测到沙盒时降级为 `guided`；服务名中带空格和引号时转义正确 |
| R2 | 只读的冲突扫描（macOS 先做） | 用本机 fixture 测试：两个 VPN 中有一个已连接时输出 C1/C4；解析器由 utun4 接管时输出 C2；Wi‑Fi 手动 DNS 时输出 D2 |
| R3 | 清理 DNS 缓存（三个桌面平台 + 移动端清理 App 缓存） | 按平台断言命令序列；提权失败时给出正确提示；执行完调用验证 |
| R4 | 修复 DNS（手动 DNS 恢复为 DHCP，带快照和撤销） | 快照、修改、验证失败时回滚到原值；**不修改没有手动 DNS 的网络服务** |
| R5 | 修复隧道配置：重建自身配置 + 关闭残留代理（T1/T3） | 只关闭**端口与我们一致**的代理；其他厂商的 VPN 配置永远不在修改列表里 |
| R6 | 移除收集密码的 `resetXrayAndConfig(password)`，改用 `privileged_runner` | 静态断言：repair 目录和 NativeBridge 中没有接收密码的 API |
| R7 | 其他平台的冲突扫描（Windows / Linux / Android） | 各平台 fixture |
| R8 | 修复记录和导出（可复制的前后快照） | 快照序列化稳定 |

---

## 7. 待确认

1. ~~macOS 最终是否上 Mac App Store？~~ **已决定上 MAS（2026-09-19）**，见 §4。还剩一个问题：是否**同时保留** Developer ID 直装版本？如果保留，桌面三端的 macOS 行可以恢复 `inAppPrivileged`；代码已通过 §4.2 的渠道维度预留好。
2. 本机 OneXray 与 XConnect 并存，是长期常态还是迁移过渡期？（`onexray-xconnect-migration-matrix.md`）如果长期并存，C1/C4 的提示文案需要单独设计。
3. UU 残留的确认：需要用户执行一次 `sudo launchctl print system/com.netease.uumac.helper`，并查看 06:30–07:30 的 `sudo log show`（§0.2 第 3 条）。
4. T4（签名问题）：本机没有签名身份，所以本地构建的包在这台 Mac 上**永远无法**保存 VPN 配置。这是开发环境问题，与自修复功能无关，但需要单独排期解决。
