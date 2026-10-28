# XConnect Google Play 上架准备材料

> 快照日期：2026-10-16（Asia/Shanghai）  
> 代码：`bb4e874a1e3615d33d5fcc4241e54056fda6312c`  
> 本文只记录本地构建、材料准备和待办；未上传 Google Play，未提交审核。

## 构建与签名证据

| 项目 | 结果 |
| --- | --- |
| Application ID | `plus.svc.xconnect` |
| versionName / versionCode | `1.0.0` / `1` |
| minSdk / targetSdk | 24 / 36 |
| Play AAB | [`build/app/outputs/bundle/release/app-release.aab`](../../build/app/outputs/bundle/release/app-release.aab) |
| 设备 APK | [`build/app/outputs/flutter-apk/app-release.apk`](../../build/app/outputs/flutter-apk/app-release.apk) |
| AAB SHA-256 | `6f1fa59ebd27998fd8698449208b6c990b048daa02fed723e1eb41ec86cfb2b5` |
| APK SHA-256 | `fc475560b7b5051bf22cb08944add17ee8ee4f302bb1862755a8fd0d3a1c8d60` |
| 签名主体 | `CN=XWork Technologies LLC, OU=Mobile, O=XWork Technologies LLC, L=Seattle, ST=Washington, C=US` |
| APK 签名 | 非 debug；APK Signature Scheme v2 通过 |
| AAB 签名 | `jarsigner` 验证通过 |
| 仓库验证 | `make build-android-play` 通过 |

`versionCode=1` 只能用于尚未使用该版本号的 Play 应用。上传前必须在 Play Console 核对已存在的版本号；如果已经使用，先提升 `pubspec.yaml` 的 `+BUILD`，重新构建并重新记录哈希。

本地签名文件位于被忽略的路径，本文不记录 keystore、别名、密码或私钥内容。

## 设备验收

本次未执行设备安装和运行验收：执行时 `adb devices` 没有连接设备。连接测试设备后，至少完成以下独立检查，并保存设备型号、Android 版本、安装结果和应用日志：

1. 安装 APK：`adb install -r build/app/outputs/flutter-apk/app-release.apk`。
2. 首次启动，授予通知权限；进入二维码扫描时再授予相机权限。
3. 添加或导入测试节点，触发 Android VPN 授权。
4. 连接、断开、再次连接；确认前台通知、状态恢复和无崩溃。
5. 验证隧道内 DNS、IPv4/IPv6（如节点支持）和应用访问；确认停止后系统网络恢复。
6. 卸载重装或清除应用数据，确认本地会话、节点和日志行为符合隐私说明。

没有设备验收证据前，APK 只能称为“已签名设备测试包”，不能称为 Android 发布验收通过。

## Play Console 材料草案

### VPN 声明

- 核心功能：用户主动配置并启动系统级加密网络隧道。
- Android 实现：`android.net.VpnService`，服务声明为 VPN service，并使用前台服务通知。
- 使用目的：网络安全、隐私保护、连接可靠性和网络加速。
- 用户控制：用户在应用内选择节点并启动/停止；系统 VPN 授权由 Android 系统确认。
- 不应填写为广告、设备管理、家长控制或其他非 VPN 用途。
- 需要在真实测试中补充：断开行为、通知文案、是否支持 always-on/按应用路由，以及服务端是否记录隧道流量元数据。

### Data safety / 隐私问卷输入依据

以下是客户端代码和最终 APK 的核对结果，不替代服务端和隐私政策确认：

- 网络权限：`INTERNET`、网络状态读取；VPN 前台运行相关权限；通知权限。
- 相机：最终 APK 包含 `CAMERA`，用于用户主动使用二维码扫描时读取二维码；需确认相机图像是否只在设备上处理且不上传。
- 账号与会话：客户端向用户指定的服务端发送登录信息和 MFA 请求，并本地保存服务地址、用户名以及会话 cookie/token；需由服务端确认保存期限、用途、共享对象和删除策略。
- 节点配置：客户端本地保存用户导入或同步的节点配置，可能包含服务器地址、端口和连接凭据；需确认这些数据是否同步到服务端、是否与第三方共享。
- 诊断信息：遥测开关默认关闭；客户端实现为本地收集并展示诊断信息，不应在 Play 表单中声明为远程收集，除非服务端另有上报实现。
- VPN 业务流量：必须按实际服务端数据处理方式填写。不能仅依据客户端没有 analytics SDK 就声明“开发者绝不接触任何流量”。
- 安全：登录和同步请求应使用 HTTPS；AAB 使用上传密钥签名，Play App Signing 由 Play Console 首次上传时确认。

提交前由产品/服务端负责人确认：数据类别、是否收集、是否共享、传输加密、删除请求处理、隐私政策 URL，以及相机和 VPN 流量的最终表述。

### 账号删除

当前客户端发现“登录/登出”和本地会话清理，但未发现账号删除 API、删除按钮或可验证的账号删除网页。因此该项当前为 **未就绪**：

- 服务端提供已认证的账号删除流程，或提供 Play 可访问的账号删除网页 URL；
- 明确账号、会话、节点同步记录、日志和账单/法定留存数据的删除范围与期限；
- 在真实账号上完成一次删除请求，保存请求时间、响应和服务端完成证据，不在材料中写入密码或 token；
- 删除完成后验证客户端登出、旧 token 失效、重新登录和数据清理行为。

在上述证据完成前，不应在 Play Console 声明“支持账号删除”。

### 测试轨道

1. 创建或确认包名为 `plus.svc.xconnect` 的 Play 应用。
2. 完成商店资料、隐私政策、应用访问、内容分级、目标用户、Data safety 和 VPN 声明。
3. 核对 `versionCode` 未重复后，上传 AAB 到 Internal testing；APK 仅用于设备侧测试，不作为 Play 上传物。
4. 邀请内部测试人员，完成安装、授权、连接/断开、升级和卸载重装验收。
5. 证据完整后再提升到 Closed testing；生产发布和审核提交需要单独授权。

## 尚未完成的发布门槛

- [x] 当前 `main` 与 `origin/main` 一致
- [x] release APK/AAB 构建完成
- [x] APK/AAB 签名验证完成
- [x] 包名、版本名、版本号核对完成
- [ ] Android 真机安装和 VPN 连接验收
- [ ] Play Console 中核对历史 `versionCode`
- [ ] 服务端/隐私负责人确认 Data safety
- [ ] 提供并验证账号删除流程
- [ ] 用户明确授权后再上传 Internal testing
- [ ] 用户明确授权后再推进 Closed/Production 测试轨道
