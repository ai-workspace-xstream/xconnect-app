# XConnect-One CLI Join MVP

CLI enrollment 基线位于 Batch 02。Batch 03 在其上增加 Linux 外部 Xray-core +
WireGuard Runtime，Batch 04A 接入 canonical SignedConfig、Ed25519 验签和持久化
downgrade floor。堆叠分支最终仍以 `codex/xconnect-overlay-productization` 为 base，
并按依赖顺序合入。

## 命令

直接指定 controller：

```bash
xconnect join https://accounts.svc.plus --token-file /path/to/token
```

当前命令读取 `XCONNECT_TOKEN` 环境变量或显式 `--token-file`。推荐使用 token
文件：

```bash
xconnect join \
  'xconnect://join?controller=https%3A%2F%2Faccounts.svc.plus&network_id=net_private' \
  --config-contract auto \
  --token-file /path/to/token
```

MVP invite URL 只携带 controller、`network_id` 和 `node_id`，不接受或持久化 URL
中的访问 token。`--network-id` 和 `--node-id` 可覆盖 invite 中的选择。

其他只读命令：

```bash
xconnect status
xconnect diagnose
```

## Join 行为

Join 使用实际的 `/api/overlay/v1/devices/register`。默认
`--config-contract auto` 优先调用 `/api/overlay/v1/signing-keys`、
`/api/overlay/v1/signed-config` 和 generation ACK；`signed` 强制使用签名契约，
`legacy` 只用于明确的控制面迁移窗口，并调用旧的 `config` / `config/ack`。
checkpoint 记录 `started → device_registered → config_fetched → runtime_applied →
acknowledged`，所以接入真实 Runtime 后进程中断可以继续，完成后的相同 Join 不会
重复注册、Apply 或 ACK。

客户端严格拒绝 SignedConfig、signing-key discovery 或 ACK 中的未知字段、secret
字段、trailing JSON、错误 Content-Type 和超过 2 MiB 的响应。它只接受 UTC `Z`
整秒时间、有效的 Ed25519 `key_id`/公钥/声明窗口、当前 device/network、单调
generation、`proxy_core=xray` 与 UUID VLESS credential。固定 golden vector 与
accounts/IaC canonical fixture 保持字节一致。

signing keys 按 controller + device 隔离缓存，使用服务端 `ETag` / 304；缓存公钥仍
必须覆盖 SignedConfig 的 issued/expiry 和当前校验时间，不能延长 key 声明窗口。
首次验证并接受某 controller/device/network 的 SignedConfig 后，客户端会在
`config-contract.json` 写入最高 generation、payload digest 和永久 downgrade lock。
其后即使 signing endpoint 返回 404/503、坏签名或未知 key，也绝不回退 unsigned
legacy。generation 回退，或同 generation 对应不同 config/payload，会返回
`config_replay_detected`。auto 只允许尚未建立该 floor 的设备在 capability 404/503
时显式兼容 legacy；其他校验错误始终 fail closed。

generation ACK 只会在真实 Runtime Apply 和健康检查成功后发送。runtime 失败时
checkpoint 保持可恢复状态且不 ACK；ACK 中断重试不会重复 Apply。已有 legacy
last-known state 可由 auto 模式原地升级，并复用本机 WireGuard key。旧的
`/api/overlay/v1/config` 仍是 unsigned legacy-compatible response，文档与代码不会
把它误称为 SignedConfig。

canonical v1 的 `transport.loopback` 同时是本机 Xray UDP ingress 与 WireGuard peer
endpoint。客户端将 Xray dokodemo relay target 固定编译为服务端本机
`127.0.0.1:51820`；这不是 overlay route，也不是从 `allowed_ips` 推断出的网关地址。
因此 v1 要求 Gateway Xray 与 WireGuard 同机且 WireGuard 监听 51820。schema v2 才会
显式建模服务端 target endpoint。

本地文件写入或 Xray `run -test` 均不视为 Apply。Linux Runtime 只有在 Xray 进程
身份、本地 UDP socket 所有权和 WireGuard 接口全部验证后才返回成功。其他平台在
受保护的系统 Runtime 尚未接入时返回 `runtime_unavailable`，checkpoint 停在
`config_fetched`，绝不发送 applied ACK，也不报告 joined。

## Linux Desktop Runtime

Linux CLI 自动选择外部 Runtime，要求：

- `xray`、`wg` 和 `wg-quick` 可从 `PATH` 发现；配置包含 DNS 时，系统还需提供
  `resolvconf` 或发行版为 `wg-quick` 配置的等价集成。
- 当前版本必须以 root 运行 `join`，不会自行调用 `sudo`、`pkexec` 或携带密码。
  缺少权限会稳定返回 `runtime_permission_denied`。
- state 目录和每个 revision 目录固定为 `0700`；Xray、WireGuard、active 与
  last-known-good 文件通过同目录临时文件原子替换并固定为 `0600`。
- 先执行 `xray run -test -config <path>`，再确认 loopback UDP 端口空闲，然后启动
  Xray。readiness 在内部硬超时内同时验证 PID 仍匹配 executable/config/revision/
  启动标识、配置摘要未变，并确认该 PID 实际持有目标 UDP socket。
- 只有随后 `wg-quick up <config>` 成功且 `wg show <interface>` 验证通过才视为
  applied。任何步骤失败都会停止候选 Xray、撤销候选 WireGuard，且不会 ACK。
- 同一健康 revision 重复 Apply 不重启。新 revision 会先保留上一份有效配置；候选
  失败时重新验证并恢复 last-known-good。恢复失败返回
  `runtime_rollback_failed`，仍不会 ACK。
- 失败候选会立即删除；成功替换后只保留 active 与 last-known-good 所需的两个
  私有 revision 目录，避免 WG 私钥和 VLESS auth material 长期累积。
- PID 元数据不足、PID 被复用、可执行文件/配置路径/启动标识或配置摘要不匹配时，
  Runtime 拒绝发送信号并返回 `runtime_process_stale`，防止误杀其他进程。

`status` 只报告 revision/core/adapter 和健康布尔值；`diagnose` 只输出稳定诊断码。
外部 Xray/WireGuard 的 stdout/stderr 不透传也不落日志，UUID、WireGuard 私钥和
access token 不会进入命令输出、错误或 runtime metadata。

## macOS 边界

macOS 不启用 Linux `wg-quick` Runtime，也不调用 `sudo` 或修改系统路由。仓库的
不可协商边界要求 macOS 系统网络只由 `NEPacketTunnelProvider` 接管，因此 CLI
当前返回 `runtime_unavailable`，`diagnose` 同时给出
`protected_host_runtime_required`。后续 Packet Tunnel Host Runtime 将实现相同的
`runtime.Interface`，通过同一 Join use case 在真正应用后再 ACK。

## 安全边界与迁移缺口

- access token 只从进程环境或 token 文件读取，不写入 checkpoint、state 或 runtime
  profile，也不进入错误消息。
- checkpoint 和 last-known state 均原子写入 0700 目录中的 0600 文件。
- `config-contract.json` downgrade floor 和 `signing-keys.json` 公钥缓存也使用相同的
  0700/0600 原子写入边界；缓存只包含公开验签材料，不包含 token 或本机私钥。
- WireGuard 私钥在 MVP 中保存在上述 0600 state 文件，`status`、`diagnose` 和错误
  输出不会展示它。接入各平台 Keychain/Keystore/Credential Manager 后必须迁出
  文件。
- 默认 device ID 暂由 OS 和 hostname 派生，可能在克隆主机上冲突；生产注册应通过
  `--device-id` 提供平台安全存储中生成的稳定唯一 ID。
- v1 只接受 controller wire runtime `xray-core`，内部 core ID 固定为 `xray`；
  内嵌路径 adapter 为 `libXray`，Linux 外部路径 adapter 为 `xray-core`。其他
  core/runtime 在 Apply 和 ACK 前失败，绝不接受 sing-box。
- 不实现或携带 `apply-playbooks-client` 等服务器静态配置命令。

## 稳定错误码

CLI 使用可机器识别的错误码，包括：

- `authentication_failed`
- `access_denied`
- `controlplane_unavailable`
- `controlplane_rejected`
- `invalid_config`
- `invalid_signed_config` / `invalid_signing_keys` / `invalid_signature`
- `signing_key_unknown` / `signing_key_window`
- `signed_config_expired` / `signed_config_future` / `signed_config_unavailable`
- `config_replay_detected` / `config_downgrade_blocked`
- `unsupported_runtime_core`
- `runtime_apply_failed`
- `runtime_unavailable`
- `runtime_dependency_missing`
- `runtime_permission_denied`
- `runtime_process_stale`
- `runtime_rollback_failed`
- `state_io` / `state_conflict`
