# Windows 构建指南

本文档说明如何在 Windows 平台编译 XConnect 所需的 `libgo_native_bridge.dll` 动态库并构建桌面应用。

## 1. 安装依赖

1. 安装 [Go](https://go.dev/dl/) 1.20+，并确保 `go` 在 `PATH` 中。
2. 安装 [Flutter](https://docs.flutter.dev/get-started/install/windows) SDK。
3. 安装 MinGW-w64，并确保 `x86_64-w64-mingw32-gcc` 在 `PATH` 中。

## 2. 编译 Go 共享库

在项目根目录执行：

```bash
bash build_scripts/build_windows.sh
```

该脚本会将 `go_core` 编译为 `bindings/libgo_native_bridge.dll`，供 Dart FFI 通过 `DynamicLibrary.open` 加载。

APP 集成使用仓库锁定的 `libXray` submodule，不需要额外的 Xray core submodule。

如果你在排查 `go build` 相关问题，也可以进入 `go_core/` 目录单独执行构建命令并检查 `CGO_ENABLED`、`CC` 和 MinGW 工具链是否正确。

Windows System Tunnel 使用名为 `XConnect` 的 Wintun 接口。应用仅在 Xray
运行、该接口已启动且 Windows 默认路由已指向该接口后报告隧道已连接；这可将
引擎启动失败、接口创建失败和路由未生效区分开来。

## 3. 构建 Flutter 桌面应用

推荐直接执行：

```bash
make build-windows-x64
```

`build-windows-x64` 目标会先运行 `build_scripts/build_windows.sh`，再执行 `flutter build windows --release`。同时，Windows 的 CMake 安装步骤会把 `bindings/libgo_native_bridge.dll` 一并复制到 `build/windows/x64/runner/Release/`，避免生成缺少核心 bridge DLL 的安装目录。

如果你只想手动执行 Flutter 构建，也可以运行：

```bash
flutter clean
flutter pub get
flutter build windows
```

前提是你已经先生成了 `bindings/libgo_native_bridge.dll`。如果 DLL 缺失，CMake 会直接报错并停止构建。

## 4. Release Packaging

本地或 CI 打包 ZIP 时，请执行：

```powershell
./build_scripts/package_windows_bundle.ps1
```

该脚本会从 `bindings/libgo_native_bridge.dll` 复制最新 bridge 产物到 `build/windows/x64/runner/Release/`，然后将整个 Release 目录压缩为 `xconnect-windows.zip`。

为了降低对目标机器 VC Runtime 预装状态的依赖，脚本会优先从本机 Visual Studio Build Tools 的 redist 目录补齐 `msvcp140.dll`、`vcruntime140.dll` 和 `vcruntime140_1.dll`。

如果打包目录里缺少 `wintun.dll`，脚本还会自动从官方 `wintun.net` 下载 `Wintun 0.14.1`，校验 SHA-256 后提取 `bin/amd64/wintun.dll` 到发布目录。这样标准 ZIP 与单文件 launcher 都能在应用目录旁拿到 `wintun.dll`。

## 5. 单文件 Windows Launcher

如果你需要一个“单文件分发”的 `xconnect.exe`，请执行：

```powershell
./build_scripts/package_windows_single_file.ps1
```

该脚本会生成：

- `build/windows/x64/portable/xconnect.exe`

这个文件是一个 **self-extract launcher**：它会把 Flutter Windows 运行时、`flutter_windows.dll`、`data/`、插件 DLL 与 `libgo_native_bridge.dll` 一起嵌入到单个外层 `xconnect.exe` 中，启动时自动解压到用户缓存目录后再拉起内层运行时。

> 说明：基于当前 Flutter Windows 发布形态，真正“无任何运行时文件、直接把 Flutter engine 和资源全部静态并入同一个原生 PE”的方式并不现实。这里提供的是可落地的单文件分发方案。

## 6. 打包 MSI 安装包

CI 发布的 Windows 安装包现在默认是 MSI。在 Windows 环境执行：

```powershell
./build_scripts/package_windows_msi.ps1
```

脚本会基于 `build/windows/x64/runner/Release/` 下的 Flutter Release 产物生成 `xconnect-windows.msi`，并自动补齐 `libgo_native_bridge.dll`、VC Runtime 与 `wintun.dll`。

如果你还需要 Microsoft Store 分发包，项目仍然保留 MSIX 打包脚本：

```powershell
./build_scripts/package_windows_msix.ps1
```

该脚本会根据根目录下的 `msix_config.yaml` 创建 `.msix` 文件。

## 配置保存与启动验收

连接配置、节点列表和服务描述文件统一保存在 `%LOCALAPPDATA%\XConnect`。
未提供 `LOCALAPPDATA` 时使用 `%USERPROFILE%\AppData\Local\XConnect`。
导入连接无需加载原生 DLL，也无需提升整个应用权限；节点列表按完整快照覆盖保存。
升级后首次读取节点列表时，若新位置不存在该文件，会复制旧安装目录中的
`vpn_nodes.json`，原有配置路径继续保留。旧目录保持原状。

发布流水线的 Flutter 测试必须在未提供原生 bridge 的环境中通过，包含导入成功、
保存失败重试及节点快照不重复的验证。流水线测试通过之后才会进入平台构建。

Windows 运行验收需使用实际安装包：普通权限启动并导入连接，确认用户目录中的
配置和节点列表均已写入；再次导入后重启应用，确认节点不重复。随后验证核心
进程启动、授权取消后的重试、停止和再次启动，并单独验证实际网络连接。
代码和单元测试通过不代表安装包或设备连接验收通过。

## Windows 原生网络接口与启动设计

保留现有 Wintun 官方签名驱动、Windows 网络 API 和独立 `xconnect-core.exe`，
UI 普通权限运行，网络核心按需通过 UAC 提升权限。Wintun 提供三层适配器；
适配器地址、DNS 和路由必须由应用配置，不能假设驱动会自动完成。
参见 [Wintun 官方集成说明](https://www.wintun.net/) 和
[Windows 地址配置 API](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-createunicastipaddressentry)。

本客户端使用 `198.18.0.1/30` 与 `fdfe:dcba:9876::1/126` 作为接口本地地址，
通过核心的 `gateway` 字段传入；这不是远端节点地址。DNS 跟随当前用户选择的
系统隧道解析器。默认路由仍由现有核心管理，出站 socket 绑定物理接口。
部署前需检查与其他网络接口、虚拟化软件或 VPN 的地址冲突；本次未实现自动选段。

原实现没有写入上述地址和 DNS 字段；当前固定版本核心在字段为空时不会调用
`SetIPAddresses` / `SetDNS`。这是配置缺口；是否为某台设备的唯一故障原因仍需现场日志证明。

核心在 `RunXray` 成功后写入 `startup.json` 就绪状态。UI 的原生调用在工作 isolate
执行，避免等待 UAC 和初始化时阻塞 Flutter。进程存活不再直接等同于启动完成：
最多等待 12 秒就绪，之后继续检查接口与默认路由。状态文件只记录阶段和可取得的
系统错误码，不写入完整配置或原始错误内容。系统错误码为 0 表示未提取到错误码，
不是成功。驱动必须存在于核心旁的 `bin/wintun.dll`。

恢复进程记录时，先核对预期安装路径和实际进程映像，再执行停止；无法读取身份或
访问进程时保留错误，不盲目处理 PID。高权限停止使用目标 PID 并检查退出码。
未来若改为常驻服务，应另行设计带身份认证、访问控制和明确命令集的 IPC，避免 UI
直接持有长期高权限；该服务改造不属于本次修复。

PR CI 的 `Windows core lifecycle` 在 Windows runner 上验证就绪确认、超时和错误码，
并构建独立核心。这不等于签名安装包、真实适配器及网络连通性验收。还需验证用户
取消 UAC 后重试、接口地址与 DNS、停止后系统网络恢复、切换物理网络和重新连接。
