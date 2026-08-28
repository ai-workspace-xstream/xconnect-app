# XConnect-One Client/CLI 实施更新记录

状态日期：2026-08-28  
本仓职责：`xconnect` CLI、XConnect-APP 产品插件、SignedConfig/policy consumer 和五平台宿主边界

## 产品边界

- 对外 CLI 二进制为 `xconnect`，核心生命周期是 join、sync、up/down、credential rotate
  和 leave。
- v1 只允许 Xray-core/libXray；不探测、启动或回退到 sing-box。
- macOS/iOS 隧道由 PacketTunnelProvider 所有。macOS CLI 不运行 sudo，也不直接修改
  系统路由。
- raw `xdc_`/`xenr_` 不进入普通 state、Flutter preferences、日志、diagnose 或终端输出。

## 已完成并推送的批次

| 批次 | 远端分支 | SHA | 结果 |
|---|---|---|---|
| 00 | `codex/xconnect-batch-00-docs` | `ba0cc8b` | 产品化设计和仓库边界 |
| 01 | `codex/xconnect-batch-01-product-plugin` | `f05d97c` | XConnect-One 内置产品插件 |
| 02 | `codex/xconnect-batch-02-cli-join` | `6b42f5e` | `xconnect join` MVP |
| 03 | `codex/xconnect-batch-03-desktop-runtime` | `1258af6` | 桌面 runtime abstraction |
| 04A | `codex/xconnect-batch-04-signed-config-client` | `59bba5d` | SignedConfig v1 验签与 replay floor |
| 04B | `codex/xconnect-batch-04-invite-join` | `02fd25a` | 一次性 invite Join |
| 05 | `codex/xconnect-batch-05-mobile-enrollment` | `3b899bc` | 移动端 enrollment 和 protected host 边界 |
| 06 | `codex/xconnect-batch-06-cli-lifecycle-policy` | `f762fd3` | CLI 生命周期、policy consumer 和 crash recovery |
| 07 | `codex/xconnect-batch-07-device-session` | `7718ad3` | 耐久设备凭据、session sync、rotate/leave 恢复和五平台存储边界 |
| 08 | `codex/xconnect-batch-08-signed-config-v2` | `18d328e` | 显式 v2 consumer、policy binding 和原子 apply/readback/ACK |

## Batch 07 状态机

- Join 在 apply/ACK 前先把耐久设备凭据写入受保护存储；短 enrollment bearer 只进入
  内存或受限 checkpoint，并在成功 ACK 后删除。
- `xconnect sync` 执行 mint session → fetch/verify → transactional apply → runtime
  readback → ACK；ACK 中断可恢复，健康的相同 revision 不重复 apply。
- signing-key ring 更新必须与 Join 信任环以相同 key id/public key 重叠，并只在配置
  apply、ACK 和 last-known state 成功后持久化。
- rotation 先保存本地 pending successor，再只发送 id/verifier；丢响应后探测 successor，
  不生成第三份秘密。
- 普通 leave 先保存 nonce，收到远端终态 receipt 后再清理本地。`--local-only` 是显式
  恢复操作，不声称远端已撤销。
- Linux 使用 0700/0600 原子文件；macOS 使用 Keychain 且 secret 不进入 argv；Windows
  使用 Credential Manager。iOS/Android 当前只有 protected operation bridge，native
  Keychain/Keystore + VPN transaction 尚未启用并保持 fail-closed。

## Batch 08 SignedConfig v2 consumer

- 只有显式请求 v2；默认仍按严格 SignedConfig v1 解析，不接受静默降级。
- 在构造 policy 请求前先验证 SignedConfig 签名；policy path 必须同源且与签名的
  generation/digest/media type 一致。
- 拒绝绝对 URL、跨源 redirect、media type/digest 不符、低 generation，以及相同
  generation 的不同 digest。
- config 与 policy 同一事务 staging/apply/readback，成功后才 ACK 并推进 replay floor；
  失败保留 LKG。

## 验证证据

- Batch 07 通过相关 Go test/race/vet、Flutter analyze、152 个 Flutter tests、
  `check_xconnect_one_runtime.sh`，以及 Linux/macOS/Windows CLI 编译和 Android/iOS
  credential package build。
- Batch 08 通过 v1/v2、同源/digest/media/replay、事务恢复的目标测试、race 和多目标
  编译。
- 仓库根全量 Go tests 和 `cmd/xconnect-core` 仍要求 sibling `libXray` checkout；当前
  缠绕依赖缺失，不将根门禁记为通过。
- 这些是自动化与编译证据，不是五平台签名安装包、真机/实机数据面或 live Accounts
  producer E2E。

## 当前限制与发布状态

- Accounts SignedConfig v2 producer/policy artifact 尚未完成，因此 Batch 08 尚无真实
  producer-consumer 联调证据。
- macOS/iOS PacketTunnelProvider、Android VpnService/JNI、Windows Service/Wintun 和
  Linux owned runtime 尚未全部连接到同一可发布生命周期。
- iOS/Android protected secret bridge 仍是 fail-closed stub；不声称移动端数据面完成。
- 当前批次保留在特性分支，未创建新的 PR；后续 PR base 为
  `codex/xconnect-overlay-productization`，创建前需再次取得用户确认。

