# Android Release Packet Tunnel 真机验证

用于验证 Android Release 包在真实设备上的安装、启动、System VPN 权限、IPv4 数据面、DNS 和应用可用性。适用于出现“界面已连接但应用无网络”、首次启动较慢或怀疑缓存残留的情况。

## 前置条件

1. Android SDK、NDK 和 JDK 已安装；设备已打开 USB 调试并在 `adb devices` 中显示为 `device`。
2. 使用本仓库构建的 Release APK。不要用旧的 `build/` 目录或其他分支产物做验证。
3. 节点配置已导入，且节点服务器域名能在隧道启动前解析到 IPv4。

## Step 1：构建并核对 APK

```bash
export JAVA_HOME=/Users/shenlan/.local/devtools/jdk17/Contents/Home
export ANDROID_SDK_ROOT=/Users/shenlan/.local/devtools/android-sdk
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export ANDROID_NDK_HOME="$ANDROID_SDK_ROOT/ndk/28.2.13676358"
export PATH="$JAVA_HOME/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$PATH"

flutter build apk --release \
  --dart-define=BRANCH_NAME=local \
  --dart-define=BUILD_ID=android-release-verify \
  --dart-define=BUILD_DATE=$(date +%Y-%m-%d)

ls -lh build/app/outputs/flutter-apk/app-release.apk
```

记录 APK 路径、文件时间和构建输出。安装前确认这三个信息对应当前源码。

## Step 2：安装、启动和清理旧会话

```bash
DEVICE=35221JEHN05AOH
ADB="$ANDROID_SDK_ROOT/platform-tools/adb"

"$ADB" -s "$DEVICE" install -r build/app/outputs/flutter-apk/app-release.apk
"$ADB" -s "$DEVICE" shell am force-stop plus.svc.xconnect
"$ADB" -s "$DEVICE" shell am start -n plus.svc.xconnect/.MainActivity
```

首次启动或安装更新后等待 10–30 秒再判断页面状态。若画面停留在黑屏，先唤醒设备、收起通知面板，再检查前台 Activity；Flutter 冷启动本身不能作为网络失败依据。

## Step 3：确认 VPN 拓扑

在 App 内连接节点后执行：

```bash
"$ADB" -s "$DEVICE" shell dumpsys connectivity \
  | rg -m1 'VPN CONNECTED extra: VPN:plus.svc.xconnect'
"$ADB" -s "$DEVICE" shell ip route
```

预期：

- 存在 `tun0` 和 `0.0.0.0/0 -> tun0`。
- VPN UID 范围排除 `plus.svc.xconnect` 自身 UID；Xray 的节点、DNS socket 必须留在底层网络，避免回到正在消费的 TUN。
- 默认关闭 IPv6 时不应配置可用的 `::/0 -> tun0`；系统显示 `::/0 unreachable` 属于没有 IPv6 隧道地址时的合成路由，不代表 IPv6 数据面已启用。

## Step 4：确认 DNS 和节点引导

```bash
"$ADB" -s "$DEVICE" logcat -d -t 3000 \
  | rg 'XConnectPacketTunnel|packet tunnel start failed'
```

预期日志包含 `profile dns4=2` 和 `packet tunnel engine started`。如果配置没有 DNS，服务会回退到字面量 `1.1.1.1`、`8.8.8.8`；`dumpsys connectivity` 中应看到：

```text
DnsAddresses: [ /1.1.1.1,/8.8.8.8 ]
```

Android 服务会在旧隧道停止后再次解析节点 outbound 的域名，将可用 IPv4 写入本次运行配置，并通过 `excludeRoute` 排除节点 `/32`。TLS SNI 和 XHTTP Host 仍使用原域名。

## Step 5：应用层验证

保持 VPN 连接，依次执行以下验证，并为每个应用截图：

1. Chrome 冷启动 `https://www.google.com` 或 `https://api.ipify.org`，等待 10–20 秒；首次页面加载比已有标签页慢是正常的。
2. 启动 X，等待时间线和图片资源完成加载。X 可能通过 `NetworkRequest` 声明 `NOT_VPN`，这类请求会主动选择底层网络，不能用来证明 Packet Tunnel 没有接管其他应用。
3. 在每次测试前记录当前时间、连接持续时间和 `tun0` 收发计数：

```bash
"$ADB" -s "$DEVICE" shell ip -s link show tun0
```

## 故障判定

| 现象 | 判定方向 |
|------|----------|
| `DnsAddresses` 为空，Chrome 报 `Failed to read DnsConfig` | DNS 没有下发；检查 profile 的 `dnsServers4` 和服务兜底日志 |
| `ping google.com` 成功，但 HTTPS 页面空白 | 原始 DNS 可用，继续检查 Xray 节点出站、TLS/XHTTP 或应用自己的网络选择 |
| X 报错但 `NetworkRequest` 含 `NOT_VPN` | 应用主动要求底层网络；与 VPN 路由接管是两个路径 |
| TUN 有 RX/TX 增长但页面不加载 | 只能证明流量进入 TUN，不能证明节点出站成功；检查节点 IPv4 固定、`excludeRoute` 和引擎错误 |
| Wi‑Fi 首次成功、切换网络或冷启动失败 | 优先检查节点域名 bootstrap；不要把 Wi‑Fi 成功当成缓存证明 |

## 缓存与重测

先关闭 XConnect 服务并重新打开目标应用，再重新连接节点；不要一开始清除应用数据，以免删除节点配置。对 Chrome 使用新标签页和全新 URL，避免旧页面缓存。只有在需要验证“全新安装”行为时，才卸载 App 后重新安装，并重新导入节点。

## 回滚

若新包无法建立 VPN，可在 App 内断开连接，或执行：

```bash
"$ADB" -s "$DEVICE" shell am force-stop plus.svc.xconnect
```

然后安装上一份已验证 APK。代码回滚只涉及 Android Packet Tunnel 服务和对应文档/变更记录；不要删除用户节点数据。
