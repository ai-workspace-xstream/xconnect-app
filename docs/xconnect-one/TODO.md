# XConnect-One Client/CLI TODO

状态日期：2026-08-28

## 已解除的合同阻断

- [x] SignedConfig v2 consumer 已在 Batch 08 (`18d328e`) 完成：显式 v2、严格 v1 默认、
  同源 path、digest/media/replay floor 和原子 apply/readback/ACK。

## P0：真实五平台 runtime 与 host bridge

- [ ] macOS：将 join/sync/up/down 接入现有 PacketTunnelProvider + libXray，完成 App
  Group/Keychain transaction、崩溃恢复、entitlement、签名和实机网络切换测试；不使用 sudo。
- [ ] iOS：实现 Swift protected credential/config operation bridge，复用
  PacketTunnelProvider，覆盖后台恢复、App/Extension 状态交接、Keychain accessibility、
  entitlement 和真机测试。
- [ ] Android：实现 Kotlin protected bridge、Keystore、VpnService/JNI/libXray、前台服务、
  进程重建以及 always-on/lockdown 行为。
- [ ] Windows：接入受控 Service/Wintun/libXray，完成 Credential Manager/DPAPI、
  非管理员 UI、服务升级、失败回滚和 sleep/resume。
- [ ] Linux：完成 Xray/WireGuard owned runtime、最小权限 helper、systemd、0700/0600
  secrets、NetworkManager/systemd-resolved 兼容和发行版矩阵。
- [ ] 每个平台在 native capability/bridge 不可用时返回稳定 fail-closed 错误，不伪造
  connected；运行时只允许 Xray-core/libXray，不增加 sing-box。

## P0：真实控制面联调

- [ ] 等 Accounts v2 producer/policy endpoint 完成后，覆盖默认 v1、显式 v2、Vary/cache、
  key rotation、跨源 redirect、错误 media/digest、低 generation 和同代不同 digest。
- [ ] 用真实 Accounts 设备凭据覆盖 Join 消耗、session mint、ACK 恢复、rotation 丢响应、
  leave receipt 重放、suspend/revoke 和控制面暂时不可用。
- [ ] 与 Gateway staging 验证 ACL allow/deny、配置 generation、policy digest、runtime
  readback 和 LKG 一致，不用客户端策略替代 Gateway 权威 enforcement。

## P1：发布与运维

- [ ] 建立 macOS/Windows/Linux/iOS/Android CI 制品矩阵、版本注入、SBOM、签名、公证、
  checksum、安装/升级/降级和回滚验证。
- [ ] 补齐 `xconnect diagnose` 的脱敏证据、用户 Join 指南、管理员恢复手册和兼容矩阵。
- [ ] 在真机/实机保存 cold start、sleep/resume、进程 kill、断网、证书轮换和 runtime
  crash 的恢复证据。
- [ ] 不修改或删除 Playbooks 静态 `group_vars`；客户端 Join/Leave 只作用于 Accounts。

## PR

- [ ] 当前没有新 PR。核对长期分支与已有 PR 后，按批次提交到
  `codex/xconnect-overlay-productization`；实际创建前需再次取得用户确认。
