# XConnect-One CLI Join MVP

本实现位于堆叠分支 `codex/xconnect-batch-02-cli-join`，依赖 Batch 01 Product
Plugin 基线。最终 PR 仍以 `codex/xconnect-overlay-productization` 为 base，合并前
必须先合入 Batch 01。

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

Join 使用实际的 `/api/overlay/v1/devices/register`、`config` 和 `config/ack`。
checkpoint 记录 `started → device_registered → config_fetched → runtime_applied →
acknowledged`，所以接入真实 Runtime 后进程中断可以继续，完成后的相同 Join 不会
重复注册、Apply 或 ACK。

当前 `/api/overlay/v1/config` 是 controller 现行的 legacy-compatible
`OverlayConfigV1`，不是 SignedConfig。SignedConfig projection、Ed25519 验签、
generation replay 防护和 last-known-good rollback 属于后续 migration。
本批实现已按 accounts canonical contract commit `01b8093` 复核现行路径与字段。

本 Batch 不把本地文件写入视为 Apply。生产 CLI 默认使用 fail-closed Runtime：在
系统 Packet Tunnel/VpnService/Windows Service/Linux service 尚未接入时返回
`runtime_unavailable`，checkpoint 停在 `config_fetched`，绝不发送 applied ACK，
也不报告 joined。成功、重复 Join 和中断恢复由注入 Fake Runtime 的测试覆盖。

## 安全边界与迁移缺口

- access token 只从进程环境或 token 文件读取，不写入 checkpoint、state 或 runtime
  profile，也不进入错误消息。
- checkpoint 和 last-known state 均原子写入 0700 目录中的 0600 文件。
- WireGuard 私钥在 MVP 中保存在上述 0600 state 文件，`status`、`diagnose` 和错误
  输出不会展示它。接入各平台 Keychain/Keystore/Credential Manager 后必须迁出
  文件。
- 默认 device ID 暂由 OS 和 hostname 派生，可能在克隆主机上冲突；生产注册应通过
  `--device-id` 提供平台安全存储中生成的稳定唯一 ID。
- v1 只接受 controller wire runtime `xray-core`，内部归一化为 core ID `xray` 和
  adapter `libXray`；其他 runtime 在 Apply 和 ACK 前失败。
- 不实现或携带 `apply-playbooks-client` 等服务器静态配置命令。

## 稳定错误码

CLI 使用可机器识别的错误码，包括：

- `authentication_failed`
- `access_denied`
- `controlplane_unavailable`
- `controlplane_rejected`
- `invalid_config`
- `unsupported_runtime_core`
- `runtime_apply_failed`
- `runtime_unavailable`
- `state_io` / `state_conflict`
