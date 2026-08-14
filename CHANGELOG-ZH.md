# XConnect v1.0.0

_发布日期：2026-08-14 — 标签 `v2026.08.14-1938`，合并 commit `27a312d`，分支 `main`_

本文记录上一版日发布标签 `v2026.8.14` 到 `v2026.08.14-1938` 之间的变更。

## 标签之前

- 已具备 Packet Tunnel 数据面探测、App 日志持久化、Xray 引擎日志、出口地址族诊断和 Go 运行时指标。
- PR #50 已定位 iOS 蜂窝网络 DNS 死锁，并完成第一阶段的节点地址固定方向。
- 仍存在陈旧 DNS 设置、iOS 旧 Packet Tunnel 会话影响新启动、服务器域名直连解析开关重复等问题。

## ✨ 本标签包含的功能与修复

- iOS 启动 Packet Tunnel 前解析出站服务器，支持系统 DNS、字面量 IP UDP DNS 和字面量 IP DoH 回退。
- 将节点运行地址固定为 IP，并保留 TLS SNI/XHTTP Host 域名，同时加入 `/32` 排除路由。
- 解析失败时 fail-closed，取消 VPN 启动，不再退回按域名连接。
- 新连接开始前等待旧 Packet Tunnel 进入 `disconnected`，避免旧隧道继续捕获解析请求。
- 删除“服务器域名直连解析”及其陈旧 iOS 偏好设置。
- 保留 Desktop/macOS 的基础 DNS 和隧道 DNS 设置，并将“直连 DNS”更名为“基础 DNS”。
- 代理 DNS resolver 固定为 IP 字面量 Cloudflare/Google，移除过期 DNS control-plane 转发和 Darwin 死分支。
- iOS DNS schema 迁移与桌面端隧道 DNS 偏好迁移分离。
- 数据面探测增加边界、退避和挂起识别；iOS App 挂起期间的探测结果标记为不确定，不再误报网络失败。
- 保留 XHTTP 高级配置、QUIC/TUN 路由和 macOS DNS 行为。

## ✅ 本标签验证结果

- `flutter analyze lib test`：无问题。
- `flutter test`：103 个测试全部通过。
- iOS Release 构建及严格签名验证通过。
- iPhone 16e 全新安装，关闭 Wi-Fi 后使用真实 5G 连接 Tky 节点。
- `tky-proxy.svc.plus` 固定为 `43.207.194.92`，出口接口为 `pdp_ip0`。
- Xray 持续通过 `43.207.194.92:443` 建连，同时保留域名用于 SNI/Host。
- 成功会话没有 `no such host`、`仍按域名连接` 或 `No route to host` 启动失败。
- macOS Desktop Release 构建为通用 `arm64`/`x86_64`，签名验证通过。
- Packet Tunnel soak 冒烟测试无会话重启、无错误记录；完整 120 分钟真实流量压测仍属于后续工作。

## 📚 标签之后的文档补充

以下提交位于发布 tag 之后，仅补充调查记录，不改变已发布二进制：

- `docs/ios-cellular-dns-deadlock-handoff.md`：重整历史 handoff 并更新最终状态。
- `docs/ios-cellular-dns-deadlock-debug-record-2026-08-14.md`：记录完整时间线、根因、构建误判、真机证据、压力测试和发布过程。

## 早期 v1.0.0 记录

- Tunnel Mode 连接后执行数据面探测，采用 settle delay 和有界重试；探测失败只提示，不主动断开隧道。
- iOS App 日志写入 `Library/Caches` 下的有界轮转文件，便于物理设备事后诊断。
- 数据面探测严格遵守时间预算，并对失败重试采用退避策略。
- 限制 Packet Tunnel 会话内存日志缓冲区，避免随会话无限增长。
- 调整 Go GC 节奏并回收空闲堆，降低 iOS Packet Tunnel 扩展内存占用。

## XConnect v0.3.4

_发布日期：2026-03-02_

### ✨ 功能

- 增加可复用的全局面包屑导航组件。
- 为 Logs、Help、About 页面增加面包屑导航。
- 支持 XHTTP 高级 `XMUX maxConcurrency` 配置并持久化。

### ✅ 调整

- 优化 iPhone 与 Desktop Logs 页面在长日志、窄屏和文本缩放下的可读性。
- 统一 macOS/iOS 的版本和 build metadata。
- 对旧节点文件应用 XHTTP 高级设置，并在运行时配置变化后提示重新连接。

## XConnect v0.3.5

_发布日期：2026-03-07_

- 将项目许可证从 GNU GPLv3 调整为 Apache 2.0。
- 同步更新文档和法律声明。

## XConnect v1.0.4

_发布日期：2026-04-12_

- 修复 Windows MSI 打包时根目录条目处理失败的问题。

## XConnect v0.3.0 预览版

_发布日期：2026-02-28_

- 增加 iOS System VPN 和 Apple Packet Tunnel 支持。
- 将 iOS Packet Tunnel 数据面接入静态链接的 `libxray.a`。
- 统一 DNS control plane、Xray DNS 路由和 Darwin Packet Tunnel DNS 捕获配置。
- 增加 iOS/macOS Packet Tunnel 监控、日志、配置同步和启动回滚能力。
- 增加 VLESS URI 导入以及 TCP/XHTTP 传输参数支持。

## 更早版本

### XConnect v0.2.0 — Windows Release

_发布日期：2025-06-10_

- 增加 Windows 服务化部署、安装器服务注册和后台恢复能力。

### XConnect v0.1.4 — macOS Tray Support

_发布日期：2025-06-09_

- 增加 macOS 菜单栏图标和窗口切换能力。

### XConnect v0.1.3 — Linux Runner

_发布日期：2025-06-08_

- 增加 Linux Go native bridge 和 systemd 支持。

### XConnect v0.1.2 — Beta Update

_发布日期：2025-06-08_

- 增加静态更新检查、模块化更新系统、版本信息和 Xray 配置生成。

### XConnect v0.1.1 — Minor Improvements

_发布日期：2025-06-07_

- 增加“重置全部配置”、图标和资源处理改进。

### XConnect v0.1.0 — First Public Preview

_发布日期：2025-06-06_

- 首个公开预览版本，支持 XTLS/VLESS 网络加速、macOS 原生集成、双架构 Xray 和 Flutter UI。
