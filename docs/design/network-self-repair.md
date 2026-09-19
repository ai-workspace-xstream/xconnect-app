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

✓ 表示 App 内可执行；◐ 表示需要系统授权弹窗（管理员密码、UAC 或 polkit），由系统弹出；⚑ 表示只能引导用户；— 表示不适用。

### 3.1 清理 DNS 缓存（D1）

| 平台 | 做法 | 权限 |
|---|---|---|
| macOS | `dscacheutil -flushcache`，然后 `killall -HUP mDNSResponder`（逻辑与 `dns-flush.sh` 一致） | ◐ 通过 `osascript … with administrator privileges` 调起系统密码框 |
| Windows | `Clear-DnsClientCache`，再执行 `ipconfig /flushdns`（与 `dns-cache.ps1` 一致） | ◐ 通过 UAC 提权（在各 Windows 版本上是否必须提权，要在 PR 中验证） |
| Linux | 依次尝试 `resolvectl flush-caches`、`nscd -i hosts`、重载 dnsmasq | ◐ 通过 `pkexec` 走 polkit |
| iOS | 没有公开 API 可以清理系统缓存。改为清理 **App 自身**的缓存（已固定的节点 IP、DoH 结果）并重建隧道；然后引导用户开关一次飞行模式 | ✓ + ⚑ |
| Android | 同 iOS；另外引导检查「私人 DNS」 | ✓ + ⚑ |

### 3.2 修复 DNS（D2–D8）

| 平台 | 检测 | 修复 |
|---|---|---|
| macOS | `scutil --dns` 找出接管解析的接口（C2）；`networksetup -getdnsservers` 检查手动 DNS（D2/D3）；`/etc/hosts` 中涉及我们节点域名的条目（D4） | ◐ 手动 DNS 恢复为 DHCP：`networksetup -setdnsservers <服务> Empty`。**先备份原值，可以撤销**。hosts 文件只提示，不自动改 |
| Windows | `Get-DnsClientServerAddress`、`Get-DnsClientNrptRule`、hosts 文件 | ◐ `Set-DnsClientServerAddress -ResetServerAddresses`（先备份）；NRPT 只提示 |
| Linux | `resolvectl status`，`/etc/resolv.conf` 的指向，NetworkManager 连接的 DNS 设置 | ◐ `resolvectl revert <网卡>`；`nmcli` 恢复自动 DNS（先备份） |
| iOS | 只能看到 App 自身隧道的 `NEDNSSettings` | ✓ 重建自身的 DNS 设置；⚑ 引导到「设置 → VPN 与设备管理」检查其他描述文件 |
| Android | `LinkProperties` 中的 DNS 和 `privateDnsServerName`（公开 API） | ⚑ 私人 DNS 只能引导到系统设置修改 |

### 3.3 修复隧道配置（T1–T5、C1、C4、C5）

| 平台 | 检测 | 修复 |
|---|---|---|
| macOS | `scutil --nc list` 列出**所有** VPN 配置及其连接状态（C1/C4）；多余的 utun 接口；`scutil --proxy` 显示系统代理指向我们的端口，但端口没有监听（T1） | ✓ 删除并重建**自己的** `NETunnelProviderManager`（`loadAllFromPreferences` → 删除 → 重新保存，系统会重新弹出授权，处理 T3）；◐ 关闭**指向我们端口**的系统代理（T1）；⚑ 其他 VPN 只提示「请先断开 X」 |
| Windows | `Get-NetAdapter` 找残留的 wintun / TAP 网卡；`route print` 找残留的 `0.0.0.0/1` 路由；WinHTTP / IE 代理设置 | ◐ 删除**我们创建的**路由和网卡、重启服务；⚑ Winsock 重置（T7）需要重启电脑，只给出指引并请用户确认 |
| Linux | 残留的 `tun*` 设备、`ip rule`、nft 表 | ◐ 删除**我们创建的**规则和设备、重启服务（沿用现有的 TUN 助手） |
| iOS | `NEVPNStatus` 和我们自己的配置状态 | ✓ 删除并重建自己的配置；⚑ 签名或授权问题（T4） |
| Android | `VpnService.prepare()` 的返回值（C5）；服务是否存活（O3） | ✓ 重启服务；⚑ 引导到「始终开启的 VPN」设置和电池优化设置 |

### 3.4 不做的事（红线）

1. **不动其他厂商的东西**：不结束 UU 等其他 App 的进程，不删除它们的 helper 或 LaunchDaemon，不修改或删除它们的 VPN 配置。只检测、只提示，并给出官方卸载方式。越界操作既有法律和商店审核风险，也可能搞坏用户的其他软件。
2. **不收集用户的管理员密码**：提权一律通过系统自带的对话框（osascript 管理员权限、UAC、polkit）完成。
   现有的 `NativeBridge.resetXrayAndConfig(String password)`（Windows / Linux）要求 App 接收 sudo 密码，**这是需要改掉的反模式**，放进 R6 处理。
3. **每项修复都有快照和撤销**：先记录原值，再执行修改，然后验证结果；验证失败时自动回滚。
4. **不在后台自动修复**：每次修复都由用户点击触发，并展示将要执行的命令。

---

## 4. 上架合规

| 平台 | 约束 | 对设计的影响 |
|---|---|---|
| macOS | 当前 `Release.entitlements` **没有** `com.apple.security.app-sandbox`，所以现在走的是 Developer ID 分发，可以使用 osascript 提权 | **如果要上 Mac App Store**（仓库文档中已有 App Store Connect 记录），必须开启沙盒。开启后 ◐ 类修复都要改为 ⚑（给出命令让用户复制到终端执行），或者改用 `SMAppService` 注册经过审核的特权助手。**这需要尽早定下来** |
| iOS | 只能操作 App 自己的 NE 配置 | 矩阵中的 iOS 列已按此约束设计 |
| Android | 只能调用公开 API，不需要新增权限 | 读取 `LinkProperties` 需要的是 `ACCESS_NETWORK_STATE`（诊断功能已经申请） |
| Windows / Linux | 提权必须由用户主动触发 | 符合 §3.4 |

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
  privileged_runner.dart      # osascript / UAC / pkexec 的封装，不接受密码参数
  repair_journal.dart         # 快照与撤销记录（本地 JSON）
```

- 把命令执行抽象成可注入的 `typedef CommandRunner`，测试中使用 fixture 输出，不会真正改动系统（与 `tunnel_data_plane_probe.dart` 的注入方式一致）。
- 解析器（`scutil --dns`、`scutil --nc list`、`networksetup`、`Get-DnsClientServerAddress`、`resolvectl status` 的输出）全部写成纯函数，各配一份 fixture。**本次取证得到的真实输出**（E4–E6）直接用作 macOS 的 fixture。

---

## 6. TDD 任务拆分（接在诊断的 PR1–PR8 之后）

| PR | 内容 | 先写的失败测试 |
|---|---|---|
| R1 | 新增修复标签和入口：`SettingsTabId.repair`，`SettingsTabRequest.anchor`，诊断页「如何处理？」跳转到对应修复项 | anchor 能定位到对应修复项；目标标签被过滤掉时返回 null |
| R2 | 只读的冲突扫描（macOS 先做） | 用本机 fixture 测试：两个 VPN 中有一个已连接时输出 C1/C4；解析器由 utun4 接管时输出 C2；Wi‑Fi 手动 DNS 时输出 D2 |
| R3 | 清理 DNS 缓存（三个桌面平台 + 移动端清理 App 缓存） | 按平台断言命令序列；提权失败时给出正确提示；执行完调用验证 |
| R4 | 修复 DNS（手动 DNS 恢复为 DHCP，带快照和撤销） | 快照、修改、验证失败时回滚到原值；**不修改没有手动 DNS 的网络服务** |
| R5 | 修复隧道配置：重建自身配置 + 关闭残留代理（T1/T3） | 只关闭**端口与我们一致**的代理；其他厂商的 VPN 配置永远不在修改列表里 |
| R6 | 移除收集密码的 `resetXrayAndConfig(password)`，改用 `privileged_runner` | 静态断言：repair 目录和 NativeBridge 中没有接收密码的 API |
| R7 | 其他平台的冲突扫描（Windows / Linux / Android） | 各平台 fixture |
| R8 | 修复记录和导出（可复制的前后快照） | 快照序列化稳定 |

---

## 7. 待确认

1. macOS 最终是否上 Mac App Store？这决定了 ◐ 类修复能否留在 App 内（§4）。
2. 本机 OneXray 与 XConnect 并存，是长期常态还是迁移过渡期？（`onexray-xconnect-migration-matrix.md`）如果长期并存，C1/C4 的提示文案需要单独设计。
3. UU 残留的确认：需要用户执行一次 `sudo launchctl print system/com.netease.uumac.helper`，并查看 06:30–07:30 的 `sudo log show`（§0.2 第 3 条）。
4. T4（签名问题）：本机没有签名身份，所以本地构建的包在这台 Mac 上**永远无法**保存 VPN 配置。这是开发环境问题，与自修复功能无关，但需要单独排期解决。
