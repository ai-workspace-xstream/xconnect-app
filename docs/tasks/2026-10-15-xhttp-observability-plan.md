# 客户端 / libXray：XHTTP 用户链路观测实施规划

> Status: PLANNED — 尚未实现、切换子模块或部署
> Date: 2026-10-15
> Related PRs: 尚未创建

主契约与验收以 [跨仓实施规划](../../../xconnect-edge-agent/docs/tasks/2026-10-15-xhttp-user-observability-plan.md) 为准。

采集数据统一接入现有 `observability.svc.plus` 节点与同名服务。traces 使用 `https://observability.svc.plus/otlp/v1/traces`，SDK metrics 使用 `/otlp/v1/metrics`；复用现有服务的认证入口与 Collector，不新增客户端专用的独立 ingest 服务或观测节点。

## 目标

输入 email 或 Proxy UUID 后，能定位到同一真实诊断连接，查到客户端建立、服务端出口建立、首个有效响应 payload 等待与 Xray 重启重叠证据。客户端仅提供本端实测数据；服务端身份与出口阶段由认证后的 Xray 提供。

## 当前集成事实

- App 当前 gitlink 为 `80263da83e96b2972455b0a94b13ee1a10e51391`，`.gitmodules` 仍是 `https://github.com/XTLS/libXray.git`。
- 组织目标为 `ai-workspace-xstream/libXray`，原 fork 为 `haitaopanhq/libXray`。组织目标本次读取返回 404；迁移尚未确认完成。
- 原 fork main 采用更老的 core/Go 版本，不能直接替换当前 gitlink。先对齐现有功能与 core fork 基线，保留原 fork 的必要改动。
- `libXray/xray/ping.go`、`ping_batch.go`、`nodep/measure.go` 是实测入口。当前 delay 基于 HEAD 请求；批量路径通过 `core.Dial` 进入代理内核。
- 外层 httptrace 只能看到外层 Transport 暴露的操作。入口 chrome/uTLS 握手和 H2 复用需要 core hook；目标 TLS 与入口 TLS 必须分开。
- `lib/services/telemetry/telemetry_service.dart` 当前默认关闭、只本地保存诊断信息。新远端上报采用独立、明确的开关和受控身份，不改变关闭状态的语义。

客户端必采数据：DNS、TCP、TLS、实际 HTTP/2/ALPN、H2 connection/stream 获取等待及复用状态、XHTTP 首个有效响应 payload、完整受控请求耗时。阶段通过 OTLP 导出到现有 Collector；节点/服务端 Prometheus exporter 仍通过原链路供 Grafana 使用。H2 SETTINGS 若无实际 hook 不报告推算值，首次响应头也不能代替有效 XHTTP payload。

## Fork 与 SDK 实施

1. 完成 libXray 组织迁移并核实仓库权限、历史、release/tag、workflow 与下载位置。另行提交 `.gitmodules` 与 gitlink 变更。
2. `ai-workspace-xstream/Xray-core` 完成 session/transport、uTLS、VLESS 与出口 hook，固定 SDK API 契约。core package 使用 API/hook，libXray 为宿主初始化 SDK；服务端 main 自己初始化 SDK。
3. libXray 新增显式 telemetry init/update/shutdown 接口；多次 Ping/PingBatch 不重复初始化 provider，不停止 VPN 主实例 exporter。针对 Packet Tunnel 扩展与 App 主进程分别记录 `service.instance.id`。
4. `invoke_model.go`、`invoke.go` 与各平台 wrapper 为旧 Ping 结果添加可选字段，保留现有 Delay/Error/超时哨兵兼容性。并发批量测速每个 item 使用独立 observation/connection ID。
5. 返回字段包含 schema/version、trace/connection/transport IDs、phase timings、phase_status、reused、实际协议/模式、outcome 与 coverage。缺失值为 null + 明确状态，禁止以 0 表示未观测。
6. 从原生 bridge 传递已授权诊断会话的 opaque handle、节点、expiry 与导出配置；不通过 FFI 输出 Proxy UUID、服务端 HMAC key 或内部 Collector token。
7. `go_core/go.mod` 与所有最终构建主模块显式固定 fork core：依赖自身的 replace 不会自动传递。CI 检查 `go list -m -json`、gitlink 与原生制品 manifest，覆盖 Apple、Android、Linux、Windows 的实际构建来源。

## 诊断请求与关联

- 复用真实 fork Xray outbound 发往受控固定测试目标，记录所用网络路径、实际协议、请求方法、重定向、响应校验及超时。
- XHTTP 外层仅向配置的代理入口发送非秘密 trace/observation 关联元数据；目标网站的请求不注入身份或 trace baggage。
- H2/TLS transport 可复用；每个逻辑流保留自身时间并 link 到共享建连，不能把共享 TLS 当作每次新握手。
- 对 stream-one/无原生 session ID 的模式也提供稳定关联键；对未支持的 VLESS Mux 子流返回 `unsupported_multiplexing`，不悄悄关闭现网 Mux。
- `client.transport.establish` 只代表 transport 可写；VLESS 没有独立认证 ACK 时不报告虚假的认证完成 RTT。
- `client.first_payload.wait` 从本流首个请求 payload 成功写入到首个响应 payload 交付客户端；HTTP 200、padding 或内部响应头不算目标首响应。

## 授权、网络与运行生命周期

- 首轮 UAT 对选定测试用户启用有时限的诊断窗口，100% 采集受控测试流；其他用户与旧端保持明确的 coverage 状态。
- 上报经 `observability.svc.plus` 现有服务的客户端认证入口绑定账号与设备，服务端校验自报字段；App 不获得中心后台或 Vector 的共用凭据。需要认证扩展时在现有服务内完成，不独立部署 gateway。
- 导出遵守现有 Packet Tunnel 与平台网络所有权；验证 App/扩展进程、隧道建立前后、网络切换和系统挂起，无递归埋点或导出启动死锁。
- 切换账号、退出、到期和禁用时清理内存队列、停止发送，并验证旧账号排队数据不会携带新账号凭据上传。
- 采用有界内存队列；exporter 网络请求不进入自己的诊断流。系统暂停或丢弃数据时显示 partial，关闭 VPN 不等待无界 flush。

## 客户端验收

| 场景 | 要求 |
| --- | --- |
| 新建与复用连接 | 首次 DNS/TCP/uTLS 实测；复用有 link，字段为 reused 而非 0 |
| Ping / PingBatch / 正常连接 | legacy delay 契约通过；批量并发不串连接；至少一条真实客户端流与服务端关联 |
| 服务端出口/首响应注入延迟 | 客户端体验上升且服务端匹配阶段可查询，不把 target TLS 误标成入口 TLS |
| 断网/Collector 不可达/诊断禁用 | 数据面继续运行，内存受限，drop 与 coverage 可见 |
| 退出与切账号 | 不继续采集/发送旧账号信息；取消与过期生效 |
| 旧 server / 旧 client / Mux 未覆盖 | 连接兼容，查询明确 legacy_peer/partial/unsupported |
| 实机与打包 | 记录 fork SHA、SDK 版本、平台、签名与实际安装/连接结果；unsigned build 不代替设备验收 |

第一轮先完成一个真实客户端平台与 H2 受控连接闭环，其余平台逐项验收后扩大。此文为规划，不宣称任一平台已完成接入。
