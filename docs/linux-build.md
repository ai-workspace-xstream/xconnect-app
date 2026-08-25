# Linux 构建须知

本文档说明如何在 Linux 平台编译 XConnect 所需的 `libgo_native_bridge.so` 动态库并构建桌面应用。

## 生成共享库

APP 集成使用仓库锁定的 `libXray` submodule；`vendor/Xray-core` 仅作为 CLI/reference
实现保留，不参与桌面 APP bridge 构建。

在仓库根目录执行：

```bash
./build_scripts/build_linux.sh
```

脚本会优先使用与 `flutter` 打包在一起的 `clang/clang++`，以确保编译出的库和桌面应用依赖同一套 glibc。如未找到则退回系统的 `clang`，二者都缺失时脚本会报错终止。

该脚本在 CI 中也会被调用，随后运行以下命令构建桌面应用：

```bash
CC=/snap/flutter/current/usr/bin/clang \
CXX=/snap/flutter/current/usr/bin/clang++ \
flutter build linux --release -v
```

如果 `flutter` 并非以 Snap 形式安装，可将上述路径替换为实际安装目录下的 `clang`/`clang++`，务必保持与 `build_linux.sh` 使用的编译器一致，否则可能出现 `pthread_*` 相关链接错误。

依赖 ImageMagick，若未安装请先安装 `convert` 命令。此外，系统托盘功能依赖 `libayatana-appindicator3-dev`（旧发行版可安装 `libappindicator3-dev`）。若缺失该库，`go build` 会因 `pkg-config` 找不到 `ayatana-appindicator3-0.1` 而报错。

## GNOME / KDE System Tunnel

Linux 发行包会在安装阶段为 `/opt/xconnect/xconnect` 授予最小网络能力
`cap_net_admin,cap_net_raw`。这让 Xray 能创建 `xconnect-tun0` 并管理其自动
路由，而不会由桌面 helper 额外创建同名接口或改写系统 DNS。

安装包依赖 `policykit`、`iproute` 和 `libcap`（Debian/Ubuntu 上为
`libcap2-bin`）。在 GNOME 或 KDE 会话中，首次启动会经 polkit 验证桌面隧道
运行条件；连接状态只有在 `xconnect-tun0` 已启动且默认路由就绪后才会变为
“已连接”。
