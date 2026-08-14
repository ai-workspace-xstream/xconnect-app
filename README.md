# XConnect

<p align="center">
  <img src="assets/logo.png" alt="XConnect Logo" width="200"/>
</p>

## Project

XConnect is a Flutter-based client for managing Xray node configs, local proxy mode, and Apple Secure Tunnel workflows in one app.
It is built for users who want a packaged desktop and mobile client with node import, tunnel diagnostics, and system-level networking support on macOS and iOS.

## TL;DR

```bash
flutter pub get
flutter analyze
flutter test
flutter run -d macos
make build-macos-arm64
```

## Downloads

<!-- SUPPORT_MATRIX:START -->
| 平台 | 架构 | 测试状态 | 下载 |
|------|------|----------|------|
| macOS | arm64 | ✅ 已测试 | [DMG](https://github.com/ai-workspace-xstream/xconnect-app/releases/download/main-158/xconnect-dev-5fa0feb.dmg) |
| macOS | x64 | ⚠️ 未测试 | — |
| Linux | x64 | ⚠️ 未测试 | [ZIP](https://github.com/ai-workspace-xstream/xconnect-app/releases/download/main-158/xconnect-linux.zip) / [AppImage](https://github.com/ai-workspace-xstream/xconnect-app/releases/download/main-158/xconnect-linux.AppImage) / [DEB](https://github.com/ai-workspace-xstream/xconnect-app/releases/download/main-158/xconnect-linux-amd64.deb) / [RPM](https://github.com/ai-workspace-xstream/xconnect-app/releases/download/main-158/xconnect-linux-x86_64.rpm) |
| Linux | arm64 | ⚠️ 未测试 | — |
| Windows | x64 | ✅ 已测试 | [ZIP](https://github.com/ai-workspace-xstream/xconnect-app/releases/download/main-158/xconnect-windows.zip) / [MSI](https://github.com/ai-workspace-xstream/xconnect-app/releases/download/main-158/xconnect-windows.msi) |
| Android | arm64 | ⚠️ 未测试 | [APK](https://github.com/ai-workspace-xstream/xconnect-app/releases/download/main-158/app-release.apk) |
| iOS | arm64 | ✅ 已测试 | [IPA](https://github.com/ai-workspace-xstream/xconnect-app/releases/download/main-158/xconnect.ipa) |

> 自动更新：当前下载链接指向 GitHub Release [`main-158`](https://github.com/ai-workspace-xstream/xconnect-app/releases/tag/main-158).
<!-- SUPPORT_MATRIX:END -->

All download buttons currently point to the latest GitHub release page.

## Snapshots

| Initial Setup | Sync Config |
| --- | --- |
| ![Initial Setup](docs/images/init-xray.png) | ![Sync Config](docs/images/sync-config.png) |

| Unlock Status | Custom Node Form |
| --- | --- |
| ![Unlock Status](docs/images/unlock-button.png) | ![Custom Node Form](docs/images/custom-node-form.png) |

## Learn More

- [User Manual](docs/user-manual.md)
- [Developer Guide](docs/dev-guide.md)
- [Architecture Overview](docs/architecture_overview.md)
- [Packet Tunnel Design](docs/packet_tunnel_provider_design.md)
- [macOS Packet Tunnel Implementation](docs/macos-packet-tunnel-implementation.md)
- [iOS Design](docs/ios-design.md)
- [FFI Bridge Architecture](docs/ffi-bridge-architecture.md)
- [MCP Server Guide](docs/xconnect-mcp-server.md)
