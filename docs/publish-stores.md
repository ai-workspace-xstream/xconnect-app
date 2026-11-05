# 应用商店发布凭证获取指南

本文档介绍如何在各大应用商店为 CI/CD 流程生成所需的凭证，并存入 GitHub Secrets 供 publish-stores 工作流使用。

## System VPN 流量方式审核

商店描述和截图使用与应用一致的 **智能路由** 和 **全局代理**。可用的说明为「智能路由按规则决定直连或经 VPN 节点转发。全局代理将系统 VPN 接管的业务流量经节点转发。DNS、系统路由和地址族覆盖取决于当前设备及配置。」设置下次从应用连接时生效。截图使用对应待审包的真实界面。

### 送审前核对

| 渠道 | 核对项 |
| --- | --- |
| App Store（iOS／macOS） | 用组织开发者账户和签名正确的 Network Extension。首次使用或购买前在 App 内说明收集的数据及用途，并让隐私政策和 App Privacy 表单与实际行为一致。对需要 VPN 许可的发行地区，在审核备注提供相应许可信息。用签名包验收 IPv6-only／NAT64、系统 VPN 授权和系统重连。 [Apple 审核指南 §2.5、§5.4](https://developer.apple.com/app-store/review/guidelines/) |
| Google Play | 在商店详情注明 `VpnService`，核对 VPN 声明及 Data safety。若通过 `VpnService` 访问或收集个人及敏感数据，在正常使用流程中单独显著披露数据、用途和分享方式，并在访问前取得用户主动同意。用已签名的 Play 包验证设备到节点加密，以及拒绝授权、重试和断开流程。用途发生变化时重新提交 VPN 声明。 [Google Play VpnService 政策](https://support.google.com/googleplay/android-developer/answer/12564964?hl=en) |
| Microsoft Store | 核对 Partner Center 隐私 URL 与实际数据处理。用提交的 Windows 包演示普通权限启动、Wintun／UAC 授权、拒绝后可重试和断开恢复。让审核员从普通用户账户复现。 [Microsoft Store 产品政策 §10.5、§10.6](https://learn.microsoft.com/en-us/windows/apps/publish/store-policies) |
| Linux 安装包 | 按具体分发渠道的包规则验收。测试普通用户运行、权限辅助组件授权和断开后的系统网络恢复。 |

### 当前代码需要补证的项目

- Apple Packet Tunnel 现有实现通过 `packetFlow` 的内部 selector 和 ivar 探测文件描述符。应用使用 NetworkExtension 并不构成该路径符合公开 API 要求的证据。Apple 送审前须移除对未公开接口的依赖，并用公开 `NEPacketTunnelFlow` 接口或 Apple 明确支持的接口验证数据面。 [Apple 公开 API 要求](https://developer.apple.com/app-store/review/guidelines/#software-requirements) · [NEPacketTunnelFlow](https://developer.apple.com/documentation/networkextension/nepackettunnelflow)
- 现有权限指引覆盖系统授权步骤。须另行验证签名包的使用前数据披露，核对节点、解析器和本地诊断实际处理的数据与隐私政策的一致性。提交前复查 [隐私政策](https://xworktech.com/privacy/) 和 [支持页](https://xworktech.com/support/) 的内容及可访问性。
- Android 导入允许传入节点传输的 `security` 值。Play 包要验证所有可用系统 VPN 配置均符合设备到节点加密要求，覆盖显式 `security=none`、旧配置和现有系统入口。若 Play 包仍可通过未加密配置建立 VPN，应先修复再提交。 [Google Play VpnService 政策](https://support.google.com/googleplay/android-developer/answer/12564964?hl=en)

### 审核备注复现路径

1. 提供审核可用的标准加密节点。需要登录时，在商店后台的审核访问字段提供限权测试账号及说明。
2. 在 App 内查看数据与权限说明，选择系统 VPN，按系统提示授权。
3. 从 **设置 → 路由** 选择智能路由并连接，检查一个直连目标和一个经 VPN 节点的目标。
4. 切换全局代理，从 App 重连，验证由系统 VPN 接管的业务流量的出口。断开并确认系统网络恢复。Apple 再从系统设置连接，核对使用最近保存的配置。

## Apple App Store

1. 登录 [App Store Connect](https://appstoreconnect.apple.com/)。
2. 在“用户与访问”中选择 **密钥** 标签页，点击“生成 API 密钥”。
3. 记录生成的 **API Key**（如 ABCD1234EF），同时保存下载的 .p8 私钥文件。
4. 在页面底部可看到 **Issuer ID**，复制备用。
5. 将私钥内容与 API Key 分别写入 GitHub Secret：
   - `APP_STORE_API_KEY`：API Key 字符串（例如 ABCD1234EF）。
   - `APP_STORE_ISSUER_ID`：Issuer ID 字符串。
6. 在 Xcode 中为 Runner 目标启用 **Network Extension** 和 **App Groups** 能力，
   对应的 entitlements 可参考 `ios/Runner/Runner.entitlements`。确保 Podfile 中
   已设置 `platform :ios, '14.0'`。
7. 如需提交 **macOS** 版本，请将 `macos/Podfile` 的平台设置调整为 `platform :osx,
   '12.0'`，并在 `Runner.xcodeproj` 中统一 `MACOSX_DEPLOYMENT_TARGET` 为 12.0。
   同时在 `macos/Runner/Release.entitlements` 启用 `com.apple.security.app-
   sandbox` 与 `com.apple.security.network.server` 权限。

## Google Play

1. 访问 [Google Play Console](https://play.google.com/console) 并选择应用。
2. 在“设置 → 开发者帐号 → 服务帐号”中点击“创建服务帐号”，跳转到 Google Cloud 页面。
3. 创建服务帐号后，授予 **Release Manager** 权限，并生成 JSON 格式的密钥文件。
4. 将该 JSON 文件内容存入 GitHub Secret `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`。

## Microsoft Store

1. 登录 [Azure 门户](https://portal.azure.com/)，在 **Azure Active Directory** 中注册一个应用程序。
2. 记录该应用的 **Tenant ID** 与 **Client ID**。
3. 在“证书与密码”页面生成一个客户端密码（Client Secret），并复制其值。
4. 前往 [合作伙伴中心](https://partner.microsoft.com/) 将上面创建的应用与 Microsoft Store 帐号关联，授予 API 权限。
5. 在 GitHub Secrets 中配置以下变量：
   - `MS_STORE_TENANT_ID`：Azure Tenant ID。
   - `MS_STORE_CLIENT_ID`：注册应用的 Client ID。
   - `MS_STORE_CLIENT_SECRET`：创建的 Client Secret。

完成凭证配置后，如需发布到 Microsoft Store，请确保构建流程额外生成 `.msix` 包（见 `windows-build.md` 第 6 步），
工作流会自动上传该文件到 Microsoft Store。

配置完成后，publish-stores 工作即会使用这些凭证自动上传构建产物，并在部署后输出对应的测试链接。

## 🔐 GitHub Secrets 配置建议

将以上信息配置在 GitHub Secrets 中，方便 GitHub Actions 流水线调用：

| Secret 名称                     | 对应平台     | 建议说明             |
|-------------------------------|--------------|----------------------|
| `APP_STORE_API_KEY`           | Apple        | Key ID               |
| `APP_STORE_ISSUER_ID`         | Apple        | Issuer ID            |
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | Google Play | 完整 JSON Key        |
| `MS_STORE_TENANT_ID`          | Microsoft    | Azure Tenant ID      |
| `MS_STORE_CLIENT_ID`          | Microsoft    | Azure 应用 Client ID |
| `MS_STORE_CLIENT_SECRET`      | Microsoft    | Azure 应用 Secret    |

---

如需使用这些密钥进行发布，请参考 `publish.yml` 工作流和文档中对应的 CI 配置。
