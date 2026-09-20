# Android 隧道建不起来：系统秒拒 VPN 授权

适用于 Android 真机上点「开始连接」后隧道始终起不来，而应用侧看不出任何报错的情况。

首次定位：Pixel 7a（lynx，Android 17 / SDK 37），2026-09-20。

---

## 为什么需要这个

这类故障最难的地方在于**应用侧完全没有错误可看**：

- `startPacketTunnel` 返回 `vpn_permission_requested`，这是一个合法的「请求已接受」
- 系统授权弹窗被拉起后立刻 finish，**从不渲染、也不获得窗口焦点**，肉眼看不到任何弹窗
- `XConnectPacketTunnelService` 从未启动，所以 `XConnectPacketTunnel` 这个 tag 一行日志都不会有

结果就是：UI 可能显示已连接（假绿），日志干净，而隧道根本不存在。必须从系统侧取证才能定位。

---

## 前置条件

1. Android 真机已通过 USB 连接，`adb devices` 能看到
2. 设备已解锁（授权弹窗在锁屏态下会被系统直接 finish）
3. 已安装本仓库构建的 XConnect，且 App 内已配置好节点

---

## Step 1：确认隧道是否真的存在

不要相信 UI，直接问系统：

```bash
adb shell cmd appops get plus.svc.xconnect ACTIVATE_VPN
```

- `allow` → 已授权。`time=...` 字段表示该权限**实际被使用过**的时间
- `ignore` / `No operations` → **从未授权成功**，这就是根因，继续 Step 2

再交叉验证两条独立证据：

```bash
adb shell dumpsys activity services plus.svc.xconnect | grep PacketTunnel
adb shell ip -o link show | grep -E 'tun[0-9]'
```

服务不存在 + 没有 tun 设备 + UI 显示已连接 = 假绿。

---

## Step 2：读取授权链路的埋点日志

`PacketTunnelController` 与 `MainActivity` 在授权链路上有固定埋点：

```bash
adb logcat -c
adb shell am force-stop plus.svc.xconnect
adb shell am start -n plus.svc.xconnect/.MainActivity
# 在 App 内点「开始连接」
adb logcat -d | grep XConnectPacketTunnel
```

正常授权失败时会看到：

```
start: prepare=needs-consent
vpn consent result: code=0 granted=false
onVpnPermissionResult: granted=false
```

**`code=0` 就是 `RESULT_CANCELED`。** 关键判读：

- 能看到 `vpn consent result` → **应用侧回调是正常的**，问题在系统，走 Step 3
- 看不到 `vpn consent result` → 回调没触发，问题在 `registerForActivityResult` 链路，查应用代码
- 看到 `startService failed: ...` → 前台服务启动被拒，查 manifest 的 FGS 权限

---

## Step 3：排除各项系统配置

逐项确认，任何一项异常都会让弹窗被秒拒：

```bash
adb shell settings get secure always_on_vpn_app        # 期望 null
adb shell settings get secure always_on_vpn_lockdown   # 期望 null 或 0
adb shell dumpsys device_policy | grep -i 'Device Owner'
adb shell dumpsys user | grep -i DISALLOW_CONFIG_VPN
adb shell dumpsys window | grep -oE 'mDreamingLockscreen=(true|false)'
```

⚠️ **`always_on_vpn_app` 卸载后不会被清除。** 它位于 `Settings.Secure`，只有系统可写，而 Android 不给应用任何卸载回调 —— 应用侧**无法**保证「卸载不残留」，只能检测并引导。更麻烦的是：当它指向一个已被卸载的包时，该包不会出现在系统 VPN 设置页里，于是**在手机 UI 上根本没有入口去关掉它**。

清除残留（系统设置，需明确授权后再执行）：

```bash
adb shell settings delete secure always_on_vpn_app
adb shell settings delete secure always_on_vpn_lockdown
```

---

## Step 4：重启设备（本次的实际解法）

如果 Step 3 全部正常但弹窗仍被秒拒，那就是 `VpnManagerService` 的**内存状态卡死**了。

判据：

```bash
adb shell uptime
adb shell cmd appops get <任意其它VPN应用> ACTIVATE_VPN
```

本次故障的特征是——设备已开机 6 天 9 小时，而本机最后一次 VPN 授权成功发生在 13.5 天前，**即本次开机之前**。也就是说自本次启动以来，没有任何应用成功拿到过 VPN 授权。

`settings delete` 只改了持久化存储，**运行中的服务不会重读**，所以必须重启：

```bash
adb reboot
adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 3; done
```

重启后解锁手机，重新点连接，授权弹窗即恢复正常。

---

## 验证方法

```bash
adb shell cmd appops get plus.svc.xconnect ACTIVATE_VPN   # allow，且带 time= 字段
adb shell dumpsys activity services plus.svc.xconnect | grep PacketTunnelService
```

`ACTIVATE_VPN: allow; time=...` 中的 `time=` 表示权限被真正行使过 —— 只有 `allow` 而没有 `time=` 说明还没走通。

---

## 回滚计划

本 Runbook 修改的系统状态都是可逆的：

| 操作 | 回滚 |
|------|------|
| `settings delete secure always_on_vpn_app` | 在 设置 → 网络和互联网 → VPN 里重新开启「始终开启 VPN」 |
| `cmd appops set ... ACTIVATE_VPN allow` | `adb shell cmd appops set plus.svc.xconnect ACTIVATE_VPN default` |
| `adb reboot` | 无需回滚 |

---

## 附：这次一并修掉的应用侧问题

排查过程中发现并修复的真实缺陷，均已补测试：

| 问题 | 根因 |
|------|------|
| 假绿：UI 显示已连接但无隧道 | `_hasActiveConnection` 只看选中节点，不看隧道真实状态 |
| 失败后无法重试连接 | 按钮文案按隧道状态渲染，动作却按选中节点分支，点「开始连接」实际执行断开 |
| 代理模式被死锁 | 待授权时写入 `STATE_CONNECTING`，弹窗不返回结果就永久卡住，而代理模式拒绝在隧道「运行中」时启动 |
| 节点读写全部失败 | 依赖 `sqlite3` 却未依赖 `sqlite3_flutter_libs`，APK 内没有 `libsqlite3.so` |
| 前台服务无法启动 | targetSdk 34+ 缺少 `FOREGROUND_SERVICE_SPECIAL_USE` 与 `foregroundServiceType` |

> `sqlite3_flutter_libs` 注意：`0.6.0+eol` 是空壳版本（README 明示 "no longer does anything"），对应 `sqlite3` 3.x。配合 `sqlite3: 2.x` 必须锁 `0.5.x` 线。
