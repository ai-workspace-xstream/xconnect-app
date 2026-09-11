# XConnect App Scripts

本目录包含 XConnect 客户端开发、构建、运维以及网络/DNS 诊断相关的工具脚本。

## DNS 缓存自查与清理工具

针对客户端在 macOS、Linux、Windows 平台可能遭遇的 DNS 解析异常（特别是修改/新增 DNS 记录后命中的**系统负缓存 Negative Cache**导致 `Could not resolve hostname` 报错）：

| 脚本文件 | 适用平台 | 说明 |
| :--- | :--- | :--- |
| `dns-check.sh` | macOS / Linux | 深度对比系统底层解析（`getaddrinfo`）与公共/权威 DNS 差异，智能识别负缓存 |
| `dns-flush.sh` | macOS / Linux | 一键清空并重置系统级 DNS 缓存守护进程（macOS `mDNSResponder` / Linux `resolved`, `dnsmasq`, `nscd`） |
| `dns-cache.ps1` | Windows (PowerShell) | Windows 平台专用的 DNS Client 缓存自查与一键清空脚本 |

### 快速执行方式

#### 方式 1: 通过 Makefile (macOS / Linux)
```bash
# 执行 DNS 解析与缓存自查
make dns-check

# 一键清理 DNS 缓存 (需管理员权限)
sudo make dns-flush
```

#### 方式 2: 直接运行脚本 (macOS / Linux)
```bash
# 自查默认节点域名 (jp-xconnect.svc.plus, agent-proxy-selfhost-prod-jp.svc.plus, accounts.svc.plus)
./scripts/dns-check.sh

# 自查指定域名
./scripts/dns-check.sh my-custom-endpoint.svc.plus

# 清理缓存并自动验证
sudo ./scripts/dns-flush.sh
```

#### 方式 3: Windows (PowerShell 管理员身份)
```powershell
# 自查
.\scripts\dns-cache.ps1 -Action Check

# 清理
.\scripts\dns-cache.ps1 -Action Flush

# 先清理后自查
.\scripts\dns-cache.ps1 -Action Both
```

---

## 其他工具脚本

* `onexray-network-audit.sh`: macOS 平台网络、路由与进程连接矩阵审计。
* `ci_post_clone.sh`: Xcode Cloud 持续集成构建前置脚本。
* `clean_old_tags.sh`: Git 标签清理工具。
* `generate_icons.sh`: 多平台应用图标自动生成脚本。
