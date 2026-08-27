# Linux 构建须知

本文档说明如何在 Linux 平台编译 XConnect 所需的 `libgo_native_bridge.so` 动态库并构建桌面应用。

## 生成共享库

APP 集成使用仓库锁定的 `libXray` submodule，不需要额外的 Xray core submodule。

在仓库根目录执行：

```bash
./build_scripts/build_linux.sh
```

脚本会使用 `CC`/`CXX` 环境变量；未设置时优先查找 Flutter SDK 自带的
`clang/clang++`，再退回系统工具链，二者都缺失时脚本会报错终止。

`make build-linux-x64` 默认使用 PATH 中的 `clang`/`clang++`；如果 Flutter SDK 自带一套编译器，也可以显式设置 `CC` 和 `CXX`，并让共享库与 Flutter 桌面构建使用同一套工具链：

```bash
CC=/path/to/clang CXX=/path/to/clang++ make build-linux-x64
```

务必保持 `build_linux.sh` 与 Flutter 桌面构建使用同一套编译器，否则可能出现 `pthread_*` 相关链接错误。

Ubuntu 26.04 默认使用 GNOME Wayland。XConnect 在 Wayland 会保留标准 Dock
最小化行为；基于 X11 窗口查找的旧托盘恢复功能只在 X11 会话启用，避免窗口
最小化后无法恢复。

依赖 ImageMagick，若未安装请先安装 `convert` 命令。此外，系统托盘功能依赖 `libayatana-appindicator3-dev`（旧发行版可安装 `libappindicator3-dev`）。若缺失该库，`go build` 会因 `pkg-config` 找不到 `ayatana-appindicator3-0.1` 而报错。

## GNOME / KDE System Tunnel

Linux 发行包会在安装阶段为 `/opt/xconnect/xconnect` 授予最小网络能力
`cap_net_admin,cap_net_raw`。这让 Xray 能创建 `xconnect-tun0` 并管理其自动
路由，而不会由桌面 helper 额外创建同名接口或改写系统 DNS。

Linux bundle 使用 origin-relative `RPATH` 加载随包提供的 Go bridge；这是
 capability-marked executable 在 glibc secure-execution 模式下仍能启动的必要条件。

安装包依赖 `pkexec`/`polkit`、`iproute` 和 `libcap`（Debian/Ubuntu 上为
`libcap2-bin`）。Ubuntu 26.04 直接提供 `pkexec` 与 `polkitd`，旧版 Ubuntu
仍可通过 `policykit-1` 兼容依赖安装。在 GNOME 或 KDE 会话中，首次启动会经
polkit 验证桌面隧道运行条件；连接状态只有在 `xconnect-tun0` 已启动且默认
路由就绪后才会变为“已连接”。

完整 System Tunnel 集成需要安装 `.deb` 或 `.rpm` 包。安装脚本会部署
`/usr/libexec/xconnect/xconnect-net-helper`、polkit policy，并为主程序授予最小
网络 capability。ZIP 与 AppImage 是便携构建，只支持不需要系统 capability
的功能；它们不会修改宿主系统或静默安装特权组件。
