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

Ubuntu 26.04 默认使用 GNOME Wayland。XConnect 在 Wayland 和无法识别的会话中
保留桌面原生窗口/Dock 行为，不尝试通过 X11 隐藏窗口。X11 会话启用托盘菜单与
最小化到托盘；只有图标和实际托盘宿主均就绪时才隐藏窗口。托盘宿主退出后恢复
窗口，避免 GNOME 托盘扩展缺失时无法恢复。所有窗口操作与托盘初始化均使用
Flutter 已有的 GTK 主循环，不再另启 GTK 循环或通过窗口标题轮询。图标路径相对安装程序位置
解析，因此从 XDG/IceWM/KDE/GNOME 自动启动时不依赖当前工作目录。Linux 主程序
按桌面 display 采用单实例注册，重复启动激活同一桌面的现有窗口。不同 KDE/XRDP
与 IceWM 会话仍可各自打开窗口。托盘 Quit 使用已有窗口关闭流程。

验证 Linux 桌面集成时至少覆盖 X11 的 IceWM 和 KDE、Wayland 的 GNOME，以及从
应用菜单和 XDG autostart 启动两种入口；确认重复启动只激活一个窗口、最小化/恢复
可用，且连接、断开、系统代理和状态显示行为不变。Wayland 的原生窗口行为不依赖
托盘扩展存在。

## libXray 上游同步

Linux 桌面与托盘适配代码位于本仓库的 `linux/` 和 `go_core/bridge_linux.go`，
不修改 `libXray`。构建以父仓库 gitlink 为唯一版本来源；`go_core/go.mod` 的
`replace` 固定指向该子模块。Linux 构建与 PR 校验会拒绝版本不一致或含 tracked
改动的子模块，避免把本机未提交改动打入发布包。

升级上游时，在独立干净分支先记录旧 gitlink，fetch 上游并审查候选 commit 的
API/Go 版本和 core 依赖变化，再 checkout 明确 SHA，提交新的 gitlink。对候选
版本执行 Go vet、共享库构建以及 Linux/Android/iOS 构建和连接回归，通过 PR
合并后才用于部署。CI 与节点部署始终使用 `git submodule update --init --recursive`，
不使用 `--remote`。回滚时同时恢复父仓库 commit、gitlink 和完整安装包。

Home-Lab 的构建记录应包含应用 commit、libXray commit、包 SHA256、安装版本和
桌面类型。部署前备份 `/opt/xconnect`，保留用户配置与 OAuth 文件；部署后重新
核验 capability、动态库与实际运行的二进制。

## Home-Lab 网络职责

XConnect-One 负责 VPN 互联，包括 `10.79.0.0/24` 到 Home-Lab 的管理通路。
XConnect App 负责网络代理/系统 TUN 出站；CPA 使用系统路由，不额外设置
HTTP_PROXY、HTTPS_PROXY、ALL_PROXY 或 CPA `proxy-url`。在启用 App TUN 前核对
VPN 互联、局域网、上游服务器端点的排除路由；验收需要同时确认 VPN SSH 通路、
系统 TUN 出站、CPA 真实模型请求。GUI 窗口存在或服务 active 不代表这些检查通过。

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
