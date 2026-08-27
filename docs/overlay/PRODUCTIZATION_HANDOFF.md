# XConnect Overlay：客户端实施计划

状态：Batch 00 / planning

长期特性分支：`codex/xconnect-overlay-productization`

## 仓库职责

本仓是 XConnect 唯一终端产品仓库，负责：

- `xconnect` CLI 二进制。
- Flutter 桌面和移动 UI。
- 共享 Go enrollment/config/policy use cases。
- macOS/iOS `NEPacketTunnelProvider`。
- Android `VpnService`。
- Windows/Linux 系统服务和平台适配。
- WireGuard + Xray 安全传输的客户端生命周期。
- 配置签名验证、last-known-good、诊断和 ACK。

现有 `overlayctl` 能力迁入本仓并正式重命名为 `xconnect`。不发布 `overlayctl` 兼容二进制。

## 复用基线

- Flutter UI 和现有账号/配置同步服务。
- `go_core/` 的 Go FFI 和平台桥接。
- `libXray/` 与 Xray 构建流程。
- macOS/iOS Packet Tunnel targets。
- Android Packet Tunnel/VpnService 桥接。
- Windows、Linux 构建和安装包流程。
- 现有 functional baseline、iOS 真机 smoke 和 soak 工具。

## 目标模块边界

```text
cmd/xconnect
  └─ overlay/usecase
      ├─ overlay/controlplane
      ├─ overlay/enroll
      ├─ overlay/config
      ├─ overlay/policy
      ├─ overlay/runtime
      ├─ overlay/diagnostics
      └─ overlay/state

Flutter OverlayService
  └─ Pigeon/FFI
      └─ 相同 overlay/usecase
```

CLI 与 Flutter UI 必须调用相同 Join/Up/Down/Sync use cases，不能维护两套状态机。

## Runtime SPI

共享接口至少包括：

```go
type Runtime interface {
    Capabilities(context.Context) (Capabilities, error)
    Validate(context.Context, SignedConfig) (ValidationReport, error)
    Prepare(context.Context, SignedConfig) (PreparedConfig, error)
    Apply(context.Context, PreparedConfig) (ApplyResult, error)
    Start(context.Context, string) error
    Stop(context.Context, string) error
    Status(context.Context, string) (Status, error)
    Diagnostics(context.Context, string) (DiagnosticBundle, error)
    Rollback(context.Context, uint64) error
}
```

平台系统入口保持唯一：

| 平台 | 系统网络入口 |
|---|---|
| macOS/iOS | `NEPacketTunnelProvider` |
| Android | `VpnService` |
| Windows | Windows Service + Wintun/WireGuard backend |
| Linux | systemd + kernel WireGuard/netlink，必要时 userspace backend |

Apple 平台继续遵守仓库约束：系统网络接管只使用 Packet Tunnel，不新增 sudo 路由修改或第二种系统入口。

## 分批实施

### Batch 01：契约与 Shared Core

- 引入 Overlay OpenAPI 生成 client。
- 建立 SignedConfig、Gateway/Peer、Policy 和 Runtime 状态模型。
- 实现签名、generation、ETag 和 last-known-good 存储。
- 建立 fake control plane、fake runtime、fake clock。

退出条件：契约 golden、签名失败、generation replay 和 rollback 单元测试通过。

### Batch 02：`xconnect join` CLI

- 新增 `cmd/xconnect`。
- 实现 `join/up/down/status/config sync/diagnose/leave`。
- 将原 overlayctl Join 流程提取为可恢复状态机。
- 接入平台安全存储并保证日志脱敏。

退出条件：Linux/macOS 从干净状态完成 Join；中断可恢复；重复 Join 幂等。

### Batch 03：Flutter 共用 Join Use Case

- 新增 `OverlayService`。
- GUI 登录、邀请链接/二维码、连接和撤销调用 shared use case。
- UI 展示稳定错误 code、阶段、correlation ID 和可操作建议。
- 不在 Widget 中直接处理密钥、文件权限或 FFI。

退出条件：CLI 与 GUI 对同一 fixture 生成相同配置、状态和 ACK。

### Batch 04：桌面平台闭环

- Linux daemon/netlink/polkit。
- Windows Service、安装升级和 Wintun backend。
- macOS Packet Tunnel Overlay profile。
- 统一 status、metrics 和诊断包。

退出条件：三平台完成 `join → connect → config rotate → revoke`。

### Batch 05：移动平台闭环

- iOS Packet Tunnel enrollment/config 接入。
- Android VpnService enrollment/config 接入。
- 邀请链接、二维码、网络切换和后台恢复。
- iOS 真机内存 soak；Android Doze/进程恢复。

退出条件：iOS/Android 完成注册、连接、策略更新和撤销，并保存标准 evidence。

### Batch 06：客户端 ACL 与策略解释

- 客户端应用 compiled policy，提供快速本地拒绝。
- Gateway 仍是不可绕过的强制执行点。
- 实现 `xconnect policy explain` 和 GUI 策略诊断。
- 覆盖 IPv4/IPv6、协议、端口和规则优先级。

退出条件：客户端策略行为与控制面 compiler golden 一致；禁用本地策略不会绕过 Gateway。

## 测试门禁

基础门禁：

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
(cd go_core && go test ./...)
(cd go_core && go vet ./...)
```

每个相关 Batch 还必须执行：

- OpenAPI/JSON Schema contract tests。
- Join 状态机故障注入。
- 签名、generation、last-known-good 和 rollback cases。
- Linux/macOS/Windows build matrix。
- Android emulator 和真机 smoke。
- iOS Runner/PacketTunnel target health、真机 smoke 和 soak。
- 完整 `join → connect → policy → revoke` evidence。

## 发布物

```text
xconnect-darwin-arm64
xconnect-darwin-amd64
xconnect-linux-amd64
xconnect-linux-arm64
xconnect-windows-amd64.exe
```

App 发布物继续使用现有 DMG、MSI/MSIX、DEB/RPM、IPA 和 APK/AAB 流程。CLI 版本和 App shared core 版本必须可追踪到同一源码 revision。

## PR 策略

- 所有编码 PR 的 base 为 `codex/xconnect-overlay-productization`。
- 每个 Batch 使用独立 `codex/xconnect-batch-NN-*` 分支。
- 未经维护者明确要求，不将编码 PR 指向 `main`。
- 每个 PR 必须通过仓库现有静态检查，并列出平台验证、evidence 和 rollback。
