# Android Tunnel 模式下 Grok 历史图片间歇性加载失败记录

- 日期：2026-09-07
- 平台：Android Release，Pixel 7a 真机
- 应用：Grok（`ai.x.grok`）
- 节点传输：VLESS + XHTTP + TLS
- 状态：问题可间歇复现；本次重新进入 Grok 后恢复加载
- 结论类型：现场分析记录，未修改代码

## 现象

开启 XConnect System VPN 后，Grok 主界面可能可以打开，但历史会话中的图片无法加载。等待一段时间或重新进入应用后，图片又可以显示。

这种表现说明失败请求集中在页面附加资源或图片 CDN，不等同于 Grok 主站完全不可达。

## 已确认事实

1. Android VPN 已建立：`tun0` 存在，默认 IPv4 路由指向 TUN。
2. VPN 已下发 `1.1.1.1`、`8.8.8.8` DNS，且设备上 `ping google.com` 成功。
3. 因此当前现象不是“DNS 没有配置”或“VPN 没有接管系统流量”的直接证据。
4. Grok 冷启动期间出现 Cronet 请求流失败；此前日志还出现过：

   ```text
   POST https://grok.com/_data/v1/analytics/... failed after 3 attempts
   ```

5. X 应用的对照日志出现过 `Glide Load failed`，失败目标为 `pbs.twimg.com`，同时部分请求声明 `NOT_VPN`。这说明媒体资源可以走独立 CDN，且部分应用会主动选择底层网络；该证据不能直接证明 Grok 也声明了 `NOT_VPN`。
6. 本次等待、重试后恢复，符合连接建立后重试成功或应用缓存命中的特征。

## 根因判断

### 1. 最高概率：XHTTP 载体的 H3/QUIC 稳定性

XHTTP 的 TLS ALPN 由 `XhttpAdvancedConfig.alpn` 写入运行配置；默认值包含并优先使用 `h3`，见 [`vpn_config_service.dart`](/Users/shenlan/workspaces/ai-workspace-xstream/xconnect-app/lib/services/vpn_config_service.dart:932)。

项目已有 QUIC 排查记录：XHTTP 载体本身使用 H3 时，载体连接抖动会同时中断复用其上的 API、WebSocket 和图片请求。用户侧 UDP/443 的 QUIC 阻断不能消除载体自身的 H3 风险，详见 [`http3-quic-2026-06-19-03.md`](/Users/shenlan/workspaces/ai-workspace-xstream/xconnect-app/docs/report/http3-quic-2026-06-19-03.md:240)。

### 2. 高概率：隧道刚建立时的启动时序

Grok 在 VPN 刚显示连接后立即发起多个 API、鉴权和图片请求。如果 XHTTP 首条连接仍在握手或复用连接尚未稳定，首批请求可能超时；应用稍后重试时则成功。这与“现在又可以了”的现象一致。

### 3. 中等概率：图片 CDN 与 Grok 主站路径不同

历史图片 URL 通常由 API 返回，再由图片组件单独访问。主站 `grok.com` 能加载，并不能证明图片 CDN 的 DNS、TLS、HTTP/2 或 HTTP/3 都正常。CDN 边缘节点、签名 URL 过期或站点风控也可能只影响历史图片。

### 4. 较低概率：DNS

此前曾出现 VPN `DnsAddresses` 为空的问题，但当前 Release 已有 `1.1.1.1/8.8.8.8` 兜底，设备解析 `google.com` 正常。因此 DNS 仍需对具体图片域名验证，但不是当前第一嫌疑。

### 5. 次要因素：缓存

WebView、Cronet 或图片库可能保留已成功响应。缓存可以解释“重进后看到图片”，但不能解释全新图片 URL 在同一时段的失败，因此只能作为放大或掩盖因素。

## 建议的确认步骤

1. VPN 建立后分别等待 0 秒、10 秒、30 秒再打开 Grok，连续做 3 轮冷启动。
2. 每轮先清空日志，再过滤 Grok、Cronet 和图片域名：

   ```bash
   adb logcat -c
   adb shell am force-stop ai.x.grok
   adb shell am start -n ai.x.grok/.main.GrokActivity
   sleep 20
   adb logcat -d | rg -i 'ai\\.x\\.grok|grok\\.com|pbs\\.twimg|Glide|Cronet|net_error|SSL|UnknownHost|timeout|NOT_VPN'
   ```

3. 打开实际运行配置，确认 XHTTP 的 `tlsSettings.alpn` 是否仍含 `h3`。若包含，优先在 Tunnel 模式使用 `h2,http/1.1` 做 A/B 测试。
4. 对失败图片 URL 只提取域名进行 DNS 和 TLS 验证；不要把带鉴权参数的完整 URL 写入日志或提交。
5. 对比 VPN 关闭、VPN 已稳定 30 秒、Proxy Mode 三种状态。若只有 Tunnel 冷启动失败，优先修复 XHTTP 载体预热和 H3 配置；若两种模式都失败，则转向 CDN 风控或签名 URL。

## 后续改进建议

### P0：先把 XHTTP 载体稳定性验证闭环

- 在 Tunnel 模式下默认将 XHTTP TLS ALPN 收敛到 `h2,http/1.1`，保留 `h3` 作为明确的高级选项。
- 在实际启动的运行配置上做断言，记录最终 ALPN、节点 IPv4、DNS 数量和引擎启动时间；不要只检查保存的节点配置。
- 以“连接建立后立即打开 Grok”和“等待 30 秒后打开 Grok”做连续冷启动 A/B，观察图片失败率和首个成功请求耗时。

### P1：增加图片 CDN 级别的诊断信息

- 对请求失败只记录脱敏后的主机名、协议、错误类别、重试次数和耗时，不记录签名 URL、Cookie 或鉴权参数。
- 将 `UnknownHost`、TLS 握手失败、连接重置、HTTP 状态码和超时分开统计，避免全部归为“代理失败”。
- 对 Grok 主站、API、WebSocket 和图片 CDN 分开显示结果，让用户能判断是主站可达但媒体资源失败，还是整条隧道不可用。

### P1：补充应用选路诊断

- 在 Android 真机上记录应用是否请求 `NOT_VPN` 或显式绑定底层 `Network`。
- 对主动选择底层网络的应用给出明确提示；不要通过扩大 VPN 排除列表或域名绕过来掩盖问题。
- 将 X、Grok、Chrome 分别作为独立验证对象，避免用一个应用的成功推断其他应用也已成功。

### P2：建立可重复的回归矩阵

- 网络：Wi‑Fi、蜂窝网络、切换网络后重连。
- 状态：首次安装、重启设备、VPN 冷启动、隧道已稳定后启动应用。
- 资源：主页、历史文本、历史图片、全新生成图片、长连接。
- 模式：Tunnel、Proxy；同一节点优先，再用 `tcp + tls` 节点排除 XHTTP 特有问题。

### 退出标准

后续修复应满足：连续 10 次冷启动中历史图片无失败；切换网络后仍能恢复；运行配置不含意外的 H3 载体；日志可以明确区分 DNS、TLS、CDN HTTP 状态和应用主动绕过 VPN 四类问题。

## 相关实现与运行手册

- Android DNS、IPv4-only 和节点引导：[`XConnectPacketTunnelService.kt`](/Users/shenlan/workspaces/ai-workspace-xstream/xconnect-app/android/app/src/main/kotlin/plus/svc/xconnect/XConnectPacketTunnelService.kt:40)
- Tunnel 模式站点差异排查：[`Tunnel-Mode-Site-Diff-From-Proxy-Mode.md`](/Users/shenlan/workspaces/ai-workspace-xstream/xconnect-app/Runbook/Tunnel-Mode-Site-Diff-From-Proxy-Mode.md:38)
- Android Release 真机验证：[`Android-Packet-Tunnel-Release.md`](/Users/shenlan/workspaces/ai-workspace-xstream/xconnect-app/Runbook/Android-Packet-Tunnel-Release.md:1)
