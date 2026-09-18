# 网络自诊断（Network Self-Diagnosis）设计与交接规格

- 分支：`feat/network-self-diagnosis`（基于 `origin/main` @ `f46ec13`）
- 状态：设计稿 v1，待评审
- 风格基线：[`docs/design/ui-style-system.md`](./ui-style-system.md)。参考图（深色「已加速」面板）**只取信息结构**，不取视觉。

---

## 0. 目标与非目标

**目标**

1. 在 App 内提供「自诊断」能力，**实时**探测并显示**丢包**、**TCP 重传**、延迟、抖动。
2. 回答用户最关心的问题：**问题发生在哪一段**（本地 Wi‑Fi/路由器、运营商到节点、节点出口）。
3. 入口：从 App 页面一键跳转到「设置 → 诊断」标签页。
4. 满足 App Store / Google Play 上架要求：只用公开 API，数据只留在本机，权限按需、在用户操作时申请。
5. 依赖在 **macOS / Linux / Windows / iOS / Android** 五个平台都可用。

**非目标（本期不做）**

- ICMP ping、traceroute、局域网扫描、抓包。
- 上传诊断数据到服务端。
- 读取 Wi‑Fi SSID/BSSID（需要定位权限）。
- 隧道内每条 TCP 连接的真实重传统计（需要改 libXray，另开 issue，见 §10 PR8）。

---

## 1. 入口与导航

### 1.1 设置页新增「诊断」标签

- 在 `settings_screen.dart` 的 `_settingsTabs()` **末尾**追加第 7 个标签：
  图标 `Icons.network_check`（线性，符合 R5），文案 key `settingsTabDiagnostics`（中文「诊断」，英文 "Diagnostics"）。
- 加在末尾，不打乱现有标签顺序（ui-style-system §0.1：不改次序）。
- 这个标签在五个平台都显示，因为它的 blocks 永远不为空。

### 1.2 「自诊断」入口（App 页面 → 设置/诊断）

| 位置 | 形态 | 行为 |
|---|---|---|
| 首页连接状态卡的指标行（延迟指标旁） | `TextButton.icon(Icons.network_check, '自诊断')`，文字按钮，不加底色 | 切到「设置」页，选中「诊断」标签，**自动开始诊断** |
| 首页延迟探测失败或延迟超过阈值时 | 延迟指标本身变成可点，右侧加一个 `chevron_right` | 同上 |
| 用户直接点「诊断」标签 | — | 只进入标签页，**不自动开始**，要用户点「开始诊断」 |

为什么这样分：iOS 14+ 和 macOS 15+ 第一次连接路由器时会弹「本地网络」授权框。App Review 5.1.1 要求权限在用户操作的上下文中申请。点入口是明确的诊断意图，所以可以自动开始；只是点开标签不算。

### 1.3 跳转机制（关键实现约束）

- `_settingsTabs()` 会把**当前平台为空的标签过滤掉**（例如 iOS 没有桌面 DNS 组），所以**标签下标不稳定**。深链**必须按 id 找标签，不能按下标**。
- 新增 `enum SettingsTabId { connection, dns, routing, transport, config, system, diagnostics }`。给 `_settingsTabs()` 的每一项加上 `id`。
- 新增一个导航请求通道：`ValueNotifier<SettingsTabRequest?>`（放在 `GlobalState` 或新的 `AppNavigation` 单例里）。`SettingsTabRequest` 带 `id` 和 `autoStart` 两个字段。
  - `main.dart` 监听到请求后执行 `setState(() => _currentIndex = 2)`。桌面和移动端的页面列表里，设置都在下标 2。
  - `SettingsScreen` 监听到请求后，**按 id** 选中对应标签，然后把请求**置回 null**（消费一次）。
- 纯函数 `int? resolveSettingsTabIndex(List<SettingsTabId> visible, SettingsTabId requested)`，用单测锁定。

---

## 2. 测量模型：怎么知道问题出在哪一段

### 2.1 链路分段

```
 本设备 ──S1── 路由器(默认网关) ──S2'── 节点服务器 ──S3'── 目标站点
   └────────────── S2（直连节点，隧道外）──────┘
   └────────────────────────── S3（经隧道端到端）────────────────┘
```

| 段 | 实测什么 | 界面显示为 |
|---|---|---|
| S1 本地网络 | 本设备 → 默认网关的 TCP 连接 RTT | 本设备 → 路由器 |
| S2 接入线路 | 本设备 → 节点服务器 `address:port` 的 TCP 连接 RTT（走隧道外的底层线路） | 路由器 → 节点服务器，值为 `S2 − S1` |
| S3 出口 | 经隧道对探测 URL 做 HTTPS HEAD，复用现有 `_probeLatencyViaHttp` 和 `_latencyProbeUris` | 节点服务器 → 目标站点，值为 `S3 − S2` |
| DNS（旁路指标） | 系统解析器的 `InternetAddress.lookup` 耗时 | 详情行 |

- 节点服务器地址：从当前节点配置（`VpnNode.configPath`）的 outbound `vnext` / `servers` 中取。先把 `tunnel_endpoint_resolver.dart` 里 `pinOutboundEndpoints()`（第 319 行起）遍历 `vnext` / `servers` 的逻辑抽成纯函数 `outboundServerEndpoints(Map config)`，再复用。
- 隧道**未连接**时仍然测 S1 和 S2。这正好用来诊断「连不上」：节点不可达 = S2 丢包 100%。S3 显示「未连接」。

### 2.2 探测原语：只用 TCP 连接，不用 ICMP

- 用 `dart:io` 的 `Socket.connect(host, port, timeout: 3s)`，立刻 `destroy()`。五个平台都能用，不需要 root 或特殊 entitlement，也不起子进程。
- 结果分类：

| 结果 | 含义 | 计入 |
|---|---|---|
| 连接成功 | 可达 | RTT 样本 |
| **连接被拒（RST / ECONNREFUSED）** | **可达**：路由器常常不监听该端口，但会回 RST | RTT 样本（取到异常为止的耗时） |
| 超时（≥ 3s） | 请求或回包丢失 | 丢包 |
| 其他错误（如网络不可达） | 该段不可用 | 不可用计数，不算丢包 |

- **TCP 重传（探测级）**：内核 SYN 首次重传的 RTO 约为 1s，所以一次 SYN 丢失会让连接耗时**多出约 1s**。判定规则：
  `rtt ≥ 窗口内成功 RTT 中位数 + 800ms` 时，这次探测计为「重传」。连接虽然建立了，但途中发生过重传。
  这个规则不依赖各平台的精确 RTO 值（只要 RTO ≥ 1s 就成立）。超时设为 3s，是为了至少能捕获一次 SYN 重传。
- S1 端口发现：在诊断会话开始时依次试 `53 → 80 → 443`，第一个「成功或被拒」的端口在本次会话中固定使用。
  三个端口都超时，S1 显示「**无法测量（路由器不响应探测）**」，**不能显示为 100% 丢包**。有的路由器会静默丢弃发往关闭端口的 SYN，这里要避免误报。

### 2.3 采样与统计

| 参数 | 默认值 | 说明 |
|---|---|---|
| 采样频率 | 每段每秒 1 次 | 三段合计 ≤ 3 个连接/秒，不像扫描行为 |
| 窗口 | 最近 30 个样本（约 30s） | 滑动窗口 |
| 延迟 | 最近 5 个成功样本的中位数 | 抗毛刺 |
| 抖动 | 相邻成功样本差的绝对值的均值 | |
| 丢包率 | 超时数 / 窗口样本数 | **估算值**，界面说明里要写明 |
| 重传率（探测级） | 慢完成数 / 成功数 | |
| 预热 | 前 5 个样本只显示「采样中…」，不出结论 | 避免刚打开就误报 |

### 2.4 系统级 TCP 重传率（分平台能力，只作辅助指标）

| 平台 | 数据源 | 权限 | 实现 |
|---|---|---|---|
| Linux | `/proc/net/snmp` 中 `Tcp:` 的 `RetransSegs` / `OutSegs` 两次读数之差 | 无 | 纯 Dart 读文件 |
| macOS | `sysctlbyname("net.inet.tcp.stats")` → `tcps_sndrexmitpack` / `tcps_sndpack` | 无（与 `netstat -s` 相同） | `dart:ffi`（结构体偏移要对照 SDK 的 `netinet/tcp_var.h` 验证） |
| Windows | `GetTcpStatisticsEx`（iphlpapi.dll）→ `dwRetransSegs` / `dwOutSegs` | 无 | `dart:ffi`，**不引入** `win32` 包 |
| iOS | 沙箱限制，不可用 | — | 不显示该指标 |
| Android | Android 10 起 App 不能读 `/proc/net/*`，不可用 | — | 不显示该指标 |

- 这是**整机**统计（包含其他 App 的流量），所以归到「本设备整体」，**不参与分段判定**。
- 不可用的平台显示 `— —`，并用 tooltip 说明「此平台不提供系统级重传统计」。**不要尝试绕过**。

### 2.5 分段判定（诊断结论）

阈值集中在一个常量类 `DiagnosisThresholds` 里：

| 指标 | 注意 | 严重 |
|---|---|---|
| 丢包率 | ≥ 2% | ≥ 5% |
| 重传率 | ≥ 2% | ≥ 5% |
| 延迟 S1 / S2 / S3 | ≥ 20 / 150 / 300 ms | ≥ 50 / 300 / 600 ms |
| 抖动 | ≥ 30 ms | ≥ 80 ms |

判定规则：

1. 下游段会继承上游段的丢包，所以某一段**自身**的丢包 ≈ `max(0, loss_k − loss_{k−1})`，自身延迟 = `rtt_k − rtt_{k−1}`。
2. **最靠近设备**的「严重」段就是主因；没有严重段时，取最靠近设备的「注意」段。
3. 结论文案（全部走 l10n）：

| 结论 | 触发 |
|---|---|
| 网络良好 | 各段都正常 |
| 本地网络（Wi‑Fi / 路由器）不稳定 | S1 是主因 |
| 运营商到节点的线路丢包或拥塞 | S2 自身是主因 |
| 节点服务器不可达 | S2 丢包 100%，且 S1 正常或不可测 |
| 节点出口到目标站点异常 | S3 自身是主因 |
| DNS 解析缓慢 | 各段正常，但 DNS ≥ 500ms |
| 设备未联网 | connectivity 为 `none`，**并且** S2 全部失败（两个条件都要满足，见 §6） |

4. 每条结论都带「如何处理？」，点开一个本地 bottom sheet，列出处理建议（例如靠近路由器、换 5GHz、切换节点、改用蜂窝网络对比），**不联网**。

---

## 3. 页面规格（与现有 App 风格一致）

### 3.1 布局

「诊断」标签内容沿用设置页现有结构：顶部标题和标签条固定，下方 `SingleChildScrollView` 按顺序放 blocks，block 之间的间距是 `_groupGap = 24`，内容最大宽度 `_maxContentWidth = 900`，左对齐。**屏幕不带 AppBar**（嵌在 `IndexedStack` 里）。

从上到下：

1. **结论卡**（`SettingsGroup`，无标题）
   左侧是状态图标（线性，放在 40×40、`AppRadius.sm`、状态 muted 底色的方块里），中间是结论标题（`titleMedium`）和一行说明（`bodySmall`），右侧是主按钮「开始诊断 / 停止诊断」（`pill`，`ink` / `onInk`）。
   运行中时在卡片底部加 2px 的 `LinearProgressIndicator`，只在预热阶段出现。
   结论为非「良好」时，说明行末尾加「如何处理？」文字链接（`brand` 色）。
2. **关键指标**（4 个指标块）：端到端延迟 / 丢包率 / TCP 重传率 / 网络类型。
   数值用 `displaySmall`（30 / w700，与首页流量大数字同级），单位和标签用 `labelLarge`，数值颜色按状态取 success / warning / error。
   空值统一为 `— —`，与首页 `_emptyMetricValue` 一致。
3. **链路分段**（`SettingsGroup`，标题「链路分段」）
   节点：本设备（桌面用 `Icons.laptop_outlined`，手机用 `Icons.smartphone_outlined`）→ 路由器 `Icons.router_outlined` → 节点服务器 `Icons.dns_outlined` → 目标站点 `Icons.public`。
   节点之间是连接线，线上标注「延迟 X ms · 丢包 Y% · 重传 Z%」（`labelSmall`）。
   连接线颜色：正常用 `outlineVariant`，注意用 `warning`，严重用 `error`，主因那一段线宽加粗到 3px。
   **不使用插画**，参考图的 3D 设备图不符合 R4、R5。
4. **实时曲线**（P1，可后置）：每段 60 秒的 RTT 折线，丢包点用小竖线标出。用 `CustomPainter` 画，**不引入图表库**。
5. **详情**（`SettingsGroup` + `SettingsRow`）：网络类型、默认网关、DNS 解析耗时、当前节点、系统级重传率（仅桌面）、探测方式说明（「基于 TCP 连接探测，结果仅保存在本机」）、「复制诊断报告」（复制纯文本到剪贴板）。

### 3.2 设计 Token

| Token | Light | Dark | 用途 |
|---|---|---|---|
| `AppColors.brand` / `brandDark` | `#1F5499` | `#6B9ED8` | 链接、选中 |
| `AppColors.ink` / `onInk` | `#1F5499` / `#FFFFFF` | `#6B9ED8` / `#0F172A` | 主按钮 |
| `success` / `successMuted` | `#217346` / `#E8F4EC` | `#4EB87A` / `#143322` | 良好 |
| `warning` / `warningMuted` | `#A3580B` / `#FDF4E7` | `#E5A344` / — | 注意 |
| `error` / `errorMuted` | `#C23B38` / `#FDEBEA` | `#E57371` / — | 严重 |
| `AppRadius.sm` / `card` / `pill` | 8 / 16 / 999 | 同左 | 图标方块 / 卡片 / 按钮和 chip |
| `AppMotion.instant` / `standard` / `emphasis` | 120 / 220 / 320 ms | 同左 | 按压 / 数值和颜色过渡 / bottom sheet |

- 取色一律通过 `context.xColors` 和 `Theme.of(context).colorScheme`，**禁止写 `Color(0x…)` 字面量**。
- 零阴影，用填充代替描边（R2、R4）。
- 字号走 `TextTheme`（§3.4），不写 `fontSize:` 字面量。

### 3.3 组件

| 组件 | 文件 | Props | 备注 |
|---|---|---|---|
| `DiagnosisVerdictCard` | `lib/widgets/diagnostics/verdict_card.dart` | `verdict`, `running`, `warmingUp`, `onToggle`, `onHowToFix` | |
| `DiagnosisMetricTile` | `…/metric_tile.dart` | `label`, `value`, `unit`, `level`, `tooltip?` | `level` 取 `unknown` / `good` / `warn` / `bad` |
| `DiagnosisPathView` | `…/path_view.dart` | `segments`, `culprit?`, `axis` | 宽屏横向、窄屏纵向 |
| `DiagnosisSparkline` | `…/sparkline.dart` | `samples`, `level` | P1 |
| 详情行 | 复用 `SettingsRow` | — | |

### 3.4 状态与交互

| 元素 | 状态 | 行为 |
|---|---|---|
| 页面 | 空闲（从未运行） | 结论为「尚未诊断」，指标 `— —`，按钮「开始诊断」 |
| 页面 | 运行中 | 每秒刷新，数值变化用 `AnimatedSwitcher` 淡入淡出（`AppMotion.standard`）；按钮变为「停止诊断」 |
| 页面 | 预热（前 5 个样本） | 进度条显示，结论为「采样中…」，不给判定 |
| 页面 | 已停止 | 保留最后一次数值，显示「最后更新 HH:mm:ss」 |
| 页面 | 自动停止 | 离开标签页、离开设置页、App 进入后台（`paused` / `hidden`）或连续运行 5 分钟后停止，显示「已自动停止」 |
| 主按钮 | hover / pressed / focus | 沿用 ui-style-system §5.2 状态表 |
| 「如何处理？」 | 点击 | 打开 bottom sheet（`AppMotion.emphasis`） |
| 路由器节点 | 网关未知 | 显示「未知」，S1 隐藏，S2 标注为「本设备 → 节点服务器」 |
| 路由器节点 | 本地网络权限被拒（iOS / macOS 15+） | 显示「未授权本地网络」，详情行加「去系统设置开启」 |
| S3 | 隧道未连接 | 显示「未连接」，不探测 |
| 网络切换 | Wi‑Fi ↔ 蜂窝 / 以太网 | 清空窗口，重新解析网关，重新预热 |

### 3.5 响应式

| 可用宽度 | 变化 |
|---|---|
| ≥ 720 | 4 个指标块排成一行；链路分段横向排列 |
| < 720 | 指标块 2×2；链路分段纵向排列（节点竖排，段指标放在节点之间） |
| 手机（`_mobileBreakpoint = 900` 以下的 iOS / Android） | 同 < 720；主按钮移到结论卡底部，占满宽度 |

### 3.6 无障碍

- 焦点顺序：主按钮 → 「如何处理？」 → 指标块 → 分段 → 详情行。
- 每个指标块用 `Semantics(label: '丢包率 3%，注意')` 合并成一条朗读，不要逐字读出。
- 结论变化时用 `SemanticsService.announce` 播报，**只在结论变化时**播报，不要每秒一次。
- 状态不能只靠颜色区分：结论图标形态也要变（`check_circle_outline` / `warning_amber` / `error_outline`）。
- `MediaQuery.disableAnimations` 为 true 时动效时长为 0（ui-style-system §3.5 的 `resolveDuration`）。

### 3.7 文案与 l10n

所有文案走 `context.l10n.get('key')`，中英文两套，key 统一用 `diag` 前缀。
遵守审批词汇表：主功能词用「网络加速 / 安全隧道」，**新文案不出现「代理」**。
英文比中文长，指标块标签允许 2 行，节点名单行省略，完整名称放 tooltip。

---

## 4. 合规（上架）

| 条款 | 做法 |
|---|---|
| Apple 2.5.1 只用公开 API | 只用 `dart:io` socket、`sysctl`、`getifaddrs` 相关公开接口；不用 ICMP raw socket，不用 `ping` 子进程，不用私有框架 |
| Apple 5.1.1 / 5.1.2 数据最小化 | 不采集 SSID / BSSID，不上传；「复制报告」由用户主动操作 |
| iOS 本地网络权限 | `ios/Runner/Info.plist` 现有的 `NSLocalNetworkUsageDescription` 是 "Used to connect development tools for debug builds."，**在 Release 包里是不准确的用途说明**。改为描述诊断用途，并通过 `InfoPlist.strings` 做 zh-Hans / en 本地化 |
| macOS 15+ 本地网络权限 | `macos/Runner/Info.plist` 补上同一个 key |
| Android 权限 | 只加 `ACCESS_NETWORK_STATE`（connectivity_plus 需要）和 `ACCESS_WIFI_STATE`（网关 IP 需要），都是 normal 权限。**禁止**合并进任何定位权限 |
| Google Play 数据安全表 | 数据只在设备上处理、不收集，表单不需要改。以后如果加上传，必须同步更新 |
| 设备与网络滥用政策 | 只探测默认网关和当前节点，不扫描局域网，≤ 3 个连接/秒，不在后台运行 |
| 后台行为 | 不使用 BGTask，也不使用前台服务，进入后台即停止 |

---

## 5. 跨平台依赖矩阵

| 依赖 | 版本 | Android | iOS | macOS | Linux | Windows | 用途 |
|---|---|---|---|---|---|---|---|
| `connectivity_plus` | ^7.3.1 | ✓ | ✓ | ✓ | ✓（依赖 NetworkManager） | ✓ | 网络类型、网络切换事件 |
| `network_info_plus` | ^8.2.1（要求 Flutter ≥ 3.38.1；CI 固定 3.41.4 ✓） | ✓ | ✓ | ✓ | ✓ | ✓ | 默认网关 IP（`getWifiGatewayIP`） |
| `dart:io` | SDK | ✓ | ✓ | ✓ | ✓ | ✓ | TCP 探测、DNS、`/proc` 读取 |
| `dart:ffi` | SDK | — | — | ✓ | — | ✓ | 系统级重传计数 |

平台声明已从 pub.dev API 核对（2026-09-18）。**但声明了平台不等于每个方法都在该平台实现**，所以 PR4 第一步要逐平台验证 `getWifiGatewayIP`：

- 有线以太网下它可能返回 null。Linux 回退到读 `/proc/net/route`（纯 Dart）；macOS / Windows 有线在本期显示「未知」（P2 再用 `sysctl NET_RT_FLAGS` 或 `GetBestRoute2` 补上）。
- 没有 NetworkManager 的 Linux 上，connectivity_plus 可能返回 `none`。**不能只凭它判定离线**（见 §2.5）。

---

## 6. 边界情况

| 情况 | 处理 |
|---|---|
| 仅 IPv6 网络 | 网关是 link-local `fe80::…%iface`，本期视为「未知」 |
| Captive portal | S3 的 HTTPS 探测收到 30x 或非预期内容时，详情提示「可能需要登录当前网络」 |
| RTT ≥ 3s | 按超时计为丢包 |
| 节点配置里有多个 outbound 服务器 | 取第一个启用的 `vnext` / `servers` 条目，详情行注明 |
| 节点名很长 | 单行省略，tooltip 显示全名 |
| 诊断中切换节点 | 重置 S2、S3 窗口 |
| **Android：App 自身被排除在自己的 VPN 外**（`XConnectPacketTunnelService.kt:91` 调用了 `addDisallowedApplication(packageName)`） | App 进程发出的 HTTPS 探测**不经过隧道**。S3 必须经本地 SOCKS 入站发出；没有 SOCKS 入站时显示「此模式不支持」。**需要 owner 确认** |
| iOS / macOS：S2 的直连前提 | 依赖节点 IP 在 `excludedRoutes` 中（`PacketTunnelProvider.swift` iOS:321 / macOS:397），实现前要确认 |

---

## 7. 代码结构（给实现者）

```
lib/services/diagnostics/
  probe_primitives.dart        # typedef TcpConnectProbe + 默认 Socket.connect 实现，返回 ProbeSample
  segment_window.dart          # 滑动窗口统计（纯函数）
  stage_attribution.dart       # 分段判定（纯函数）+ DiagnosisThresholds
  gateway_resolver.dart        # network_info_plus → /proc/net/route → null
  tcp_retrans_counter.dart     # 抽象类 + Linux / macOS / Windows / Unsupported 实现
  network_diagnosis_controller.dart  # ChangeNotifier：调度、生命周期、快照
lib/widgets/diagnostics/…      # §3.3 的组件
```

- 注入风格对齐 `tunnel_data_plane_probe.dart` 的 `TunnelDnsResolver` / `TunnelTransportProbe` typedef：网络、时钟和定时器全部可注入，**不引入 mock 库**。
- 把 `home_screen.dart` 里的 `_latencyProbeUris` 和 `_probeLatencyViaHttp` 抽到 `probe_primitives.dart`，首页和诊断共用。

---

## 8. 验收标准（整体）

1. **故障注入**：
   - macOS / iOS 用 Network Link Conditioner 的 "Very Bad Network"，Linux 用 `tc qdisc … netem loss 10%`。30 秒内结论应为「本地网络不稳定」，S1 丢包 ≥ 5%。
   - 用防火墙封掉节点端口：结论为「节点服务器不可达」。
   - 路由器不响应 53 / 80 / 443：S1 显示「无法测量」，**不是** 100% 丢包。
2. 五个平台 CI 构建通过；`flutter analyze` 零新增 issue；`dart format .` 无 diff。
3. Android 合并后的 manifest（`build/app/intermediates/merged_manifests/`）**不含**任何 `LOCATION` 权限。
4. iOS Release 包的 `NSLocalNetworkUsageDescription` 是诊断用途文案。
5. 从首页点「自诊断」，在五个平台上都能落到「设置 → 诊断」并开始诊断，包括 iOS 上 DNS 标签被过滤的情况。

---

## 9. 开放问题（需要 owner 确认）

1. 首页入口的位置（§1.2）是否接受？
2. 从入口进入时自动开始，从标签进入时不自动开始，这个规则是否接受？
3. Android 上 S3 走本地 SOCKS 入站是否可行（§6）？
4. 是否需要 PR8（libXray 按连接统计 `TCP_INFO`）。这是移动端拿到**真实隧道重传**的唯一合规途径。

---

## 10. TDD 任务拆分（每项一个 PR，先写失败测试）

| PR | 内容 | 先写的失败测试 | 验收 |
|---|---|---|---|
| PR1 | 导航骨架：`SettingsTabId`、按 id 选中、导航请求通道、诊断标签占位、首页入口、l10n key | `test/widgets/settings_tab_request_test.dart`：`resolveSettingsTabIndex` 在标签被过滤时仍能按 id 命中；请求被消费一次后置为 null | 五个平台点入口都落在诊断标签 |
| PR2 | 探测原语和滑动窗口 | `test/services/diagnostics/segment_window_test.dart`：被拒计为可达并记录 RTT；超时计为丢包；`rtt ≥ 中位数 + 800ms` 计为重传；窗口 30 个样本淘汰旧值；中位数和抖动计算 | 纯函数，零网络 |
| PR3 | 分段判定 | `stage_attribution_test.dart`（表驱动）：S1 和 S2 都 10% 丢包时主因是 S1；S1 为 0、S2 为 8% 时主因是 S2；网关未知时的降级；connectivity 为 `none` 但 S2 成功时**不判离线** | §2.5 全部分支都被覆盖 |
| PR4 | 依赖、网关解析、权限、plist | `gateway_resolver_test.dart`：用 `/proc/net/route` fixture 解析 `0101A8C0` → `192.168.1.1`；解析链的顺序 | §8 第 2、3、4 条 |
| PR5 | 系统级重传计数（桌面） | `tcp_retrans_counter_test.dart`：`/proc/net/snmp` fixture 的差值计算；Windows / macOS 用假 reader；iOS / Android 返回 Unsupported | 三个桌面平台真机读数与 `netstat -s` 同量级 |
| PR6 | 控制器和生命周期 | `network_diagnosis_controller_test.dart`（注入时钟和 ticker）：每 tick 采样；进入后台时停止；5 分钟自动停止；网络切换时重置 | — |
| PR7 | UI 组件和组装 | widget 测试：空闲、运行中、预热、网关未知、离线；宽窄布局切换；Semantics 标签存在 | 亮色和暗色截图对照 §3.2；§8 第 1 条故障注入 |
| PR8（另开 issue） | libXray 暴露隧道连接的 `TCP_INFO` / `TCP_CONNECTION_INFO` | Go 侧单测 | 移动端显示真实隧道重传 |
