# Agents Guidelines

本文件为整个仓库的协作说明，适用于本仓库根目录及所有文件与子目录。请在修改代码或文档前阅读并遵循以下约定。

> 第 5 节约束产品表达、平台网络边界和权限使用。按目标平台适用，不得将单个平台的 API 作为其他平台的实现要求。

---

## 1. 项目概览

- **前端/客户端：** Flutter 应用位于 `lib/`，通过多屏幕（`screens/`）、服务层（`services/`）、工具库（`utils/`）以及组件库（`widgets/`）组织代码。
- **原生桥接：** `lib/utils/native_bridge.dart` 负责 Swift ↔ Flutter 通信；`go_core/` 提供 Go FFI 桥接，通过 `lib/bindings/bridge_bindings.dart` 暴露到 Flutter；Windows 的独立核心进程入口位于 `go_core/cmd/xconnect-core/`。Apple 平台的系统 VPN 生命周期由原生 NetworkExtension 管理，Go 核心构建与桥接以平台脚本和实际导出符号为准。
- **模板与配置：** `lib/templates/` 保存生成 Xray 配置的文本模板；`assets/` 存放静态资源与默认配置；`docs/` 内含平台构建与使用文档。
- **构建脚本：** `Makefile` 和 `scripts/` 提供多平台打包流程，`make help` 查看所有可用目标。

---

## 2. 目录速览

| 路径 | 说明 |
|------|------|
| `lib/main.dart` | 应用入口、`MainPage` 导航容器 |
| `lib/screens/` | 各功能页面（home / settings / subscription / login / logs / about / help） |
| `lib/services/` | 业务服务层（VPN 配置、账号同步、DNS、遥测等） |
| `lib/utils/` | 共享工具（`app_theme` / `app_logger` / `global_config` / `native_bridge`） |
| `lib/widgets/` | 跨界面复用组件（`app_breadcrumb` / `log_console` / `permission_guide_dialog` 等） |
| `lib/l10n/` | 中英双语字符串表 |
| `lib/templates/` | Xray 及 launchd/systemctl 配置文本模板 |
| `go_core/` | Go FFI 层与平台进程管理；Apple 系统 VPN 由 Swift 管理，核心桥接以实际构建入口为准 |
| `Runbook/` | 运维手册（发版、归档、代码质量检查等） |
| `skills/` | AI 辅助开发的可调用 skill 集合 |

---

## 3. 开发约定

### 3.1 通用流程

1. 修改前确认是否已有同类模块可复用，避免重复实现。
2. 所有代码变更必须通过格式化与静态检查：
   - Flutter/Dart：对本次修改的 Dart 文件执行 `dart format <files>`，运行 `flutter analyze`（零 issue）与相关 `flutter test`；影响公共服务或 CI 时运行完整 Flutter 测试。
   - Go：对本次修改的 Go 文件执行 `gofmt -w <files>`，在对应模块执行 `go vet ./...` 与相关测试。平台代码需注明 `GOOS` / `GOARCH` 和未执行的目标平台验证。
   - 不为格式化引入无关文件改动；静态检查、构建、安装、授权及实际网络连接是不同验收阶段。
3. 改动影响构建流程或原生行为时，PR 描述中注明目标平台及验证命令。
4. 文档、脚本或模板的行为变更需同步更新 `docs/` 或脚本注释。

### 3.2 Flutter / Dart 代码

- **lint**：遵循 `analysis_options.yaml`（基于 `flutter_lints`），不得全局关闭规则；局部例外用 `// ignore: <rule> — <reason>`。
- **l10n**：UI 文本必须通过 `context.l10n.get('key')` 获取；新增 key 必须同时添加 `en` 与 `zh` 两个译文。
- **状态管理**：复用 `GlobalState` / `ValueNotifier`，不直接操作底层服务对象。
- **日志**：通过 `addAppLog(...)` 写入；**禁止** 在生产代码中使用 `print`；不得记录密码、token 等敏感信息。
- **异步**：异步操作必须明确等待或通过 `unawaited(...)` 标注后台任务，并在适当边界处理错误；仅用户发起且需要反馈的失败通过界面提示，后台任务避免重复弹窗。
- **原生交互**：优先通过服务层（`VpnConfig` / `NativeBridge`）交互；Screen widget 不得直接处理文件路径、权限或 FFI 细节。
- **Screen AppBar 规范**：嵌入 `MainPage`（`IndexedStack`）的 Screen **不得**渲染自己的 `AppBar`（由外层统一提供面包屑）；通过构造参数（如 `breadcrumbItems`）区分"嵌入"和"独立 push"两种场景。

### 3.3 Go FFI 代码

- 操作类导出函数必须提供明确结果或错误码；释放函数、初始化回调和状态查询按其 FFI 签名返回。所有导出边界都不得将 panic 传出到 Dart。
- `C.CString` / `C.malloc` 分配的指针必须在 Go 端提供释放函数（参见 `FreeCString`）；Dart 侧调用后务必释放。
- 平台差异逻辑放 `bridge_<platform>.go`；公共导出及内存释放逻辑放在共享文件，进程管理和网络实现留在平台文件。
- **Apple 网络生命周期**：由 Swift `PacketTunnelProvider` 实现系统 VPN；`go_core/bridge_apple.go` 及 Apple 构建脚本可能提供核心桥接。不存在 `bridge_macos.go` 不代表不存在 Go 核心集成。

### 3.4 资源与模板

- 修改 `lib/templates/` 后同步更新 `services/vpn_config_service.dart` 中的生成逻辑。
- 新增静态资源放 `assets/` 并在 `pubspec.yaml` 中声明。
- 调整默认配置或示例节点时同步更新 `docs/user-manual.md`。

---

## 4. 构建与版本

### 4.1 版本号

版本唯一来源：`pubspec.yaml` 中的 `version: X.Y.Z+BUILD`。

- `X.Y.Z` → Xcode `MARKETING_VERSION`
- `BUILD` → Xcode `CURRENT_PROJECT_VERSION`（整数，每发布递增）

**Xcode Archive 前置步骤（必须执行）：**

```bash
make sync-macos-config
```

此命令重新生成 `macos/Flutter/ephemeral/Flutter-Generated.xcconfig`，确保 Xcode 读取到正确的版本号。

### 4.2 常用 Make 目标

| 目标 | 说明 |
|------|------|
| `make build-macos-arm64` | Apple Silicon macOS release + DMG |
| `make build-macos-x64` | Intel macOS release + DMG |
| `make sync-macos-config` | 同步 pubspec.yaml 版本 → Generated.xcconfig |
| `make build-ios-ipa` | iOS release IPA（需 macOS + Xcode） |
| `make build-windows-x64` | Windows x64 release |
| `make build-linux-x64` | Linux x64 release |
| `make clean` | 清理 Flutter 及生成物 |
| `make fix-macos-signing` | 清理 xattr，修复签名状态 |

### 4.3 PR Checklist

- [ ] `flutter analyze` 零 issue
- [ ] 本次修改的 Dart 文件已格式化
- [ ] `CHANGELOG.md` 已更新（若为用户可见变更）
- [ ] 目标平台构建已验证；缺少本地工具链时注明限制、CI 证据及待执行的运行验收

---

## 5. 产品、平台与安全边界

### 5.1 产品定位

XConnect 是跨平台的合法 System VPN / Secure Network Tunnel 客户端。
Apple 平台分别遵循其应用商店和 NetworkExtension 要求；其他平台遵循对应系统的网络与分发要求。
合法用途包括网络安全、隐私保护、连接稳定性和网络加速。

### 5.2 按平台选择原生网络接口

| 平台 | 系统隧道边界 |
|------|--------------|
| macOS / iOS | 系统网络接管通过 `NEPacketTunnelProvider`；不能用应用内代理、管理员路由脚本或环境变量替代系统 VPN 生命周期。 |
| Windows | 对接现有 Wintun 驱动与 Windows 原生网络接口，由独立核心进程管理适配器、地址、DNS、路由和释放。保留现有核心集成；不要求使用 Apple API。 |
| Android | 通过 Android `VpnService` 及现有原生桥接管理系统 VPN。 |
| Linux | 使用现有内核网络接口和桌面权限辅助机制；权限集中在受控辅助组件，不要求整个 UI 以管理员身份运行。 |

- 网络特权只用于目标平台必需的操作。Windows UI 普通权限运行，核心在需要时通过 UAC 请求权限；拒绝授权必须可重试。
- 不使用代理环境变量冒充系统 VPN；不以临时命令替代已定义的原生生命周期。
- DNS（含加密 DNS）属于安全隧道配置，需与地址、路由和恢复逻辑一起验证。
- 启动成功至少要求核心、目标接口及路由就绪；实际网络可用性必须独立验收。
- 故障和停止应释放本应用拥有的资源；不得盲目结束同名进程、删除其他客户端接口或修改无关网络设置。
- Windows 驱动使用官方签名分发产物并验证完整性，不在客户端启动时临时下载未知驱动。

### 5.3 文案与技术描述

- 面向用户的产品文案围绕 Secure Tunnel、System VPN、Encrypted Network、Network Acceleration / Reliability 和 Privacy Protection。
- 不宣传违法用途，不作政治或监管暗示，不承诺未验证的隐私、安全或连接能力。
- 技术文档、代码和诊断允许使用准确的系统 API、协议、驱动、权限和故障术语；不得因文案规则隐藏真实错误。
- 国家或地区名称可用于节点位置、语言、商店分发等事实信息；不得单凭地名推断用途或作合规承诺。
- 日志不得包含密码、令牌、私钥或完整连接凭据；错误反馈应保留定位所需的错误码和阶段。

---

## 6. 文档与日志

- 新增功能或显著行为更改必须同步更新 `CHANGELOG.md`。
- 面向用户的流程说明请补充或修改 `docs/` 目录下的相关指南。
- 运维操作请参考 `Runbook/` 目录；技能知识请参考 `skills/` 目录。

---

如需在子目录定义额外规范，可在该目录下创建新的 `AGENTS.md`，层级越深优先级越高。
