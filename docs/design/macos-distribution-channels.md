# macOS 双渠道分发：Mac App Store 版 + 强化直装版

- 决定（2026-09-19）：macOS 同时提供两个版本：
  1. **Mac App Store 版（MAS）**：满足上架要求，开启沙盒；
  2. **强化直装版（Direct）**：不走商店，使用 Developer ID 签名并经过公证。
- 关联：#89（沙盒迁移）、#88（自修复）、#86（自诊断）；[`network-self-repair.md`](./network-self-repair.md) §4
- 状态：设计稿 v1，待评审

---

## 0. 现状（2026-09-19 从代码核实）

| 项 | 现状 | 来源 |
|---|---|---|
| 沙盒 | 未开启，`Release.entitlements` 里只有 `application-groups` | `macos/Runner/Release.entitlements` |
| 隧道的打包形式 | **App Extension**（`com.apple.product-type.app-extension`），权限值是 `packet-tunnel-provider` | `macos/Runner.xcodeproj/project.pbxproj:366`、`macos/PacketTunnel/PacketTunnel.entitlements` |
| Bundle ID | 主程序 `plus.svc.xconnect`，隧道扩展 `plus.svc.xconnect.PacketTunnel` | pbxproj |
| 最低系统版本 | macOS 12.0 | pbxproj |
| CI 产物 | 产出 DMG，**工作流中没有找到公证（notarytool）或 Developer ID 签名步骤** | `.github/workflows/build-and-release.yml:117`、`xconnect-multi-platform-release.yaml:133` |
| 自动更新 | 没有（未接入 Sparkle 之类的更新框架） | `pubspec.yaml` / `Info.plist` |

### ⚠️ 风险：现有的直装 DMG 很可能连不上隧道

- 按 Apple 的技术说明 TN3134（Network Extension 的部署方式），在 macOS 上：
  - **App Extension 形式的 Network Extension 只能用于 Mac App Store 分发**；
  - Developer ID 分发必须改成 **System Extension**（权限值带 `-systemextension` 后缀）。
- 现在的直装 DMG 用的是 App Extension，而且没有公证。如果这个理解正确：
  - 在别人的 Mac 上它会被 Gatekeeper 拦截；
  - 即使放行，隧道也可能无法启用。
- **M0 spike 要在一台干净的 Mac 上实测确认。**

---

## 1. 两个版本的差异

| 维度 | Mac App Store 版 | 强化直装版 |
|---|---|---|
| 沙盒 | 开启 | 关闭，开启 Hardened Runtime |
| 签名与分发 | Apple Distribution 证书 + Mac App Store 描述文件，打成 `.pkg` 上传 App Store Connect | Developer ID Application 证书 → 公证（notarytool）→ staple → DMG |
| 隧道打包形式 | **App Extension**（现状，沿用） | **System Extension**（新增 target）：通过 `OSSystemExtensionRequest` 激活，用户需要在「系统设置」中批准；App 必须放在 `/Applications` 下才能激活 |
| 隧道代码 | 共用 `PacketTunnelProvider.swift`，两者只是打包方式不同 | 同左 |
| Bundle ID | `plus.svc.xconnect`（沿用现有的 App Store Connect 记录） | **建议独立**：`plus.svc.xconnect.direct`，系统扩展 ID 为 `plus.svc.xconnect.direct.PacketTunnel`。这样同一台机器装两个版本时，VPN 配置、偏好设置和 App Group 不会互相覆盖（待确认 Q1） |
| 系统代理 | 隧道下发 `NEProxySettings` | **同样使用** `NEProxySettings`，两版行为一致；`networksetup` 只保留给特权助手清理旧版本的残留 |
| 需要特权的操作 | 不做，只有 `appScoped` 和 `guided` 两种模式 | 通过**特权助手**执行（§2），对应 `inAppPrivileged` 模式 |
| Xray 核心 | 只随 App 打包，跟随 App 版本更新 | 可以单独更新核心，但下载的核心必须通过**签名校验**：我们团队签名，并且哈希与更新清单一致 |
| App 更新 | 由 App Store 负责 | 接入 **Sparkle 2**，更新清单（appcast）用 EdDSA 签名 |
| 冲突扫描 | 只能用 SystemConfiguration API 只读扫描（能覆盖多少待 S2 验证） | 完整扫描：`scutil --nc list` 列出其他 VPN；读取 `/Library/LaunchDaemons` 发现孤儿助手（例如 UU），只报告，不处理 |
| 自修复 | 在 App 内绕过 → 深链到系统设置 → 可复制的命令 | 一键执行：清理 DNS 缓存、恢复手动 DNS（带快照和回滚）、清理残留代理 |
| 权限引导 | 只需批准 NE 配置 | 需要批准系统扩展 + 后台项目（特权助手）+ NE 配置 |

两个版本的**红线相同**：
- 不动其他厂商的组件；
- 不收集用户的管理员密码；
- 每次修复都有快照和回滚；
- 不在后台自动修复。

---

## 2. 直装版的特权助手

### 2.1 方案

- 用 `SMAppService.daemon(plistName:)` 注册一个随 App 打包的 LaunchDaemon（macOS 13 及以上）。
- 用户在「系统设置 → 通用 → 登录项」中批准后，App 通过 XPC 调用它。
- 在 macOS 12 上**不装助手**，自动降级为 `guided` 模式。
- 这样用户不需要每次输入管理员密码（不再使用 osascript 管理员提示）。
- 助手可以通过 `SMAppService.unregister()` 卸载干净。

### 2.2 安全约束（助手以 root 运行，是最大的攻击面）

1. **操作是封闭的枚举**：`flushDnsCache`、`setManualDns(service, servers|empty)`、`clearLegacySocksProxy(service)`、`readSystemState`。**不接受任意 shell 命令或路径。**
2. **参数白名单**：
   - 网络服务名必须出现在助手自己执行 `networksetup -listallnetworkservices` 得到的列表中；
   - DNS 地址必须能解析成合法的 IP。
3. **校验调用方**：用 XPC 连接的 audit token 校验调用方的代码签名要求（`anchor apple generic` 且团队 ID 是我们的），拒绝其他进程调用。
4. 助手自己不访问网络，也不读取用户文件。
5. 每次调用都写审计日志，内容与修复记录（`repair_journal`）对应。

---

## 3. 工程结构

| 项 | 做法 |
|---|---|
| Xcode 构建配置 | 新增 `Release-MAS`、`Release-Direct`，各自用一个 `.xcconfig` 决定 entitlements、Bundle ID、签名方式，以及嵌入哪个隧道 target |
| 隧道 target | 保留 `PacketTunnel`（App Extension，给 MAS 版）；新增 `PacketTunnelSystemExtension`（给直装版）。两者**共用同一份** provider 源码 |
| entitlements | `Release-MAS.entitlements`：`app-sandbox`、`network.client`、`packet-tunnel-provider`、App Group<br>`Release-Direct.entitlements`：不开沙盒，使用 `packet-tunnel-provider-systemextension`、`system-extension.install`、App Group |
| Dart 侧 | 构建时传 `--dart-define=XCONNECT_DISTRIBUTION=mas|direct`，在 `DesktopPlatformCapabilities` 中增加 `distribution` 字段，运行时用 `APP_SANDBOX_CONTAINER_ID` 复核（见 `network-self-repair.md` §4.2） |
| 宿主端隧道管理 | 保存 `NETunnelProviderManager` 时，`providerBundleIdentifier` 按渠道取值；直装版在保存前先确认系统扩展已激活 |
| CI | 拆成两个 job：<br>`macos-mas`：构建 → `productbuild` 打 pkg → 通过 App Store Connect API 上传<br>`macos-direct`：构建 → Developer ID 签名 → `notarytool` 公证 → staple → DMG → 更新 Sparkle appcast<br>签名密钥沿用 #85 按环境隔离的 GCP 签名方案 |

---

## 4. 任务拆分（在 #89 中跟踪，每项一个 PR，先写失败测试）

| PR | 内容 | 先写的失败测试 / 验收 |
|---|---|---|
| M0 | spike：<br>① 在干净的 Mac 上实测现有直装 DMG 的隧道能否启用（验证 TN3134）<br>② 开启沙盒后逐项运行现有功能（S3）<br>③ 验证 S1、S2<br>结论写回本文和 `network-self-repair.md` | 只写文档 |
| M1 | 分发渠道维度：`Release-MAS` / `Release-Direct` 构建配置、`XCONNECT_DISTRIBUTION`、`DesktopPlatformCapabilities.distribution`（与 R1b 合并） | MAS 渠道下永远不会得到 `inAppPrivileged`；声明 `direct` 但检测到沙盒时降级为 `guided` |
| M2 | 隧道改为 `NEProxySettings` 下发系统代理（两个版本都做） | 隧道断开后系统代理自动撤销（集成测试） |
| M3 | 直装版的系统扩展 target 和激活流程，以及「批准系统扩展」的引导界面 | 系统扩展未激活时不保存 NE 配置，并给出明确提示 |
| M4 | 直装版的特权助手：`SMAppService.daemon` + XPC + 封闭的操作枚举 + 调用方校验 | 未知操作被拒绝；不在白名单中的网络服务名被拒绝；签名不符的调用方被拒绝 |
| M5 | MAS 版：开启沙盒 entitlements，重写权限向导，去掉 LaunchAgent 和核心下载入口 | 静态检查：MAS 构建中不存在调用 `networksetup` / `launchctl` 的路径 |
| M6 | CI 双流水线、公证、Sparkle 2 | 两个产物都能通过 `spctl --assess`；MAS 的 pkg 通过 App Store Connect 校验 |

自修复 R3–R5 在直装版上改为调用 M4 的特权助手，在 MAS 版上走 `guided` 模式。

---

## 5. 待确认

| # | 问题 | 建议 |
|---|---|---|
| Q1 | 直装版是否使用独立的 Bundle ID（`plus.svc.xconnect.direct`）？ | 建议使用。代价是两个版本的数据互不相通（节点需要重新导入，或者提供导出/导入功能） |
| Q2 | 直装版最低支持 macOS 13 吗？ | 建议最低 13。特权助手依赖 `SMAppService`，12 上只能降级为 `guided`，而 12 已不再获得 Apple 安全更新 |
| Q3 | 在 M0 验证之前，现有 DMG 是否应该暂停对外分发？ | 取决于 M0 ① 的结果 |
