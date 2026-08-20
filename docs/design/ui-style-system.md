# XConnect 设计系统：X / Grok 风格融合（风格层）

- **范围**：iOS、Android、macOS、Windows、Linux 五端
- **参考**：X / Grok iOS 客户端（会话主页 + 侧滑抽屉）
- **重点**：**主页 UI、logo、按钮风格**
- **硬约束**：**功能不变 + 布局不变**。只改「每个元素长什么样」，不改「元素在哪、有几个」
- **代码基线**：`ai-workspace-xstream/xconnect-app` @ `main`（行号基于该基线）

---

## 0. 边界

### 0.1 「布局不变」的操作性定义

**允许改（风格属性）**：颜色、填充 vs 描边、阴影、圆角、字重、字距、行高、图标线性/实心形态、
按压 / hover / focus 反馈、动效时长与曲线、以及**不改变视觉尺寸前提下**的命中区扩展。

**不允许改（布局属性）**：Widget 树结构、对齐与次序、容器宽高、`padding` / `margin` / `SizedBox` 数值、
**字号**、路由与导航项数量、每屏可执行动作的集合。

> **验收判据**：改版前后同屏截图叠加，**所有元素外框必须重合**。只有填充、描边、颜色、图标形态、
> 字重不同。字号与间距本期不动 —— 那是 §12 B 层的事。

### 0.2 本仓库既有约束（来自 `skills/xconnect-dev-constraints`）

本次改动全部落在 UI 层，但仍受这些规则约束：

| 约束 | 对本次的影响 |
|---|---|
| 所有 UI 字符串必须走 `context.l10n.get('key')`，禁止硬编码中英文 | 本期**不新增任何文案**，因此不需要新增 l10n key |
| 审批词汇表：用 Secure Tunnel / Network Acceleration，禁用 proxy 作为主功能词 | 不改文案即天然合规；§4 logo 的 `Semantics` 标签若新增需走 l10n 并遵守词表 |
| 新静态资源 → 放 `assets/` **并在 `pubspec.yaml` 注册** | §2.5 的 logo 问题正是违反了这条 |
| `flutter analyze` 零新增 issue、`dart format .` | 每个阶段 PR 的准入条件 |
| 嵌入 `MainPage`（`IndexedStack`）的 screen **不得**自带 `AppBar` | §5 改 AppBar 样式只能改 `_appBarTheme` 与 `MainPage` 本身 |
| `main` 是 preview 分支；`release/*` 受保护，只接受 cherry-pick | 本系列 PR 全部进 `main`，不直接动 `release/*` |

---

## 1. 参考风格七条

| # | 规则 | 参考图证据 | 映射到 XConnect |
|---|---|---|---|
| R1 | **墨黑优先，蓝色点缀** | 「发言」是纯黑实心 pill；全屏唯一的蓝是通知角标 | FAB 已经是深色 `#1F2937` —— 方向是对的，缺的是 token 化；真正的反例是 AppBar 那颗蓝紫渐变按钮 |
| R2 | **填充代替描边** | 促销卡、动作块、输入区全是浅灰实底，零描边 | 监控卡当前是 `填充 + 描边 + 阴影` 三件套 |
| R3 | **双档圆角** | 容器 16–20，可点小元素 full pill | 当前 8 种取值：8 / 12 / 16 / 17 / 18 / 20 / 24 / 999 |
| R4 | **零阴影** | 所有卡片零投影，靠明度差分层 | 监控卡 `blur 14 / offset (0,6)`；渐变按钮还有一层彩色投影 |
| R5 | **线性图标，实心表选中** | 底栏图标全线性；当前 tab 是实心块，不是变色 | `NavigationRail` / `NavigationBar` 用 Material 默认「变靛蓝 + 紫色 pill」 |
| R6 | **logo 单色化，三种用法** | 同一 mark：tab 实心块、空态淡水印、卡内 inline 小标 | `assets/logo.png` 既未注册也未引用（§2.5） |
| R7 | **克制的次级色** | 二级文字统一中灰 | 见 §8.3 的**数据色特例** —— 上传/下载是信息编码，不能一并去色 |

---

## 2. 现状审计

全部为本仓库实测数据。

### 2.1 主页视觉重心错位

AppBar 右上角的「添加节点」按钮（`lib/main.dart:637-670`）是全屏视觉最抢眼的元素：

```dart
gradient: const LinearGradient(colors: [Color(0xFF5B8DEF), Color(0xFF6C63FF)]),
borderRadius: BorderRadius.circular(20),
boxShadow: [BoxShadow(color: Color(0xFF5B8DEF).withValues(alpha: 0.35),
                      blurRadius: 8, offset: Offset(0, 3))],
```

蓝紫渐变 + 彩色投影 + 硬编码 hex。而**真正的主行动**是右下角那颗「开始加速 / 停止加速」FAB。
参考风格里主行动是全屏对比最强的块，其余一律退让 —— 当前正好反过来：一个次级入口
（添加节点）比主行动更抢眼。

### 2.2 卡片：填充 + 描边 + 阴影三件套

`_buildMonitoringCard`（`home_screen.dart:787-810`）同时用了三种分层手段：

```dart
color: xc.cardBackground,
borderRadius: BorderRadius.circular(24),
border: Border.all(color: xc.cardBorder),
boxShadow: [BoxShadow(blurRadius: 14, offset: Offset(0, 6))],
```

参考风格只用第一种。另外 `cardTheme` 里还有 `elevation: 1`（`app_theme.dart:_cardTheme`），
与手写卡片是两套并行的分层语言。

### 2.3 圆角与字号没有 token

| 类别 | 实测 |
|---|---|
| `BorderRadius.circular(<字面量>)` | **34 处调用、8 种取值**：12×17、16×5、999×3、8×3、24×3、20×1、18×1、17×1 |
| `fontSize: <字面量>` | **53 处**，其中 `home_screen.dart` 11 处、`login_screen.dart` 10 处 |
| `TextTheme` 定义 | **无** —— `AppTheme` 里没有任何 `textTheme`，所有字号都是就地写死 |

`17` 那处是 `_buildMetricBadge` 用 `circular(17)` 画一个 34×34 的圆（`home_screen.dart:811-820`）——
半径手算出来的圆，而不是 `BoxShape.circle`。

### 2.4 硬编码颜色违反了自家规则

`lib/utils/app_theme.dart` 开头写着：

> *Never hard-code raw hex colors in widget code; always pull from `Theme.of(context)` or these tokens.*

实际情况：`Color(0x…)` 在 theme 之外仍有 **3 处**，`Colors.*` 字面量 **6 处**。其中最关键的是 FAB
（`home_screen.dart:1332-1336`）：

```dart
backgroundColor: _hasActiveConnection
    ? const Color(0xFF3E8F5A)   // 与 AppColors.success 同值，但没走 token
    : const Color(0xFF1F2937),  // 全仓唯一一次出现的深色，没有对应 token
```

`#1F2937` 恰恰就是这次要引入的 `ink` 概念 —— 它已经存在了，只是没有名字。

### 2.5 logo 既未注册也未引用

| 事实 | 证据 |
|---|---|
| `assets/logo.png` 存在，1254×1254，**724 KB** | `ls -la assets/` |
| `pubspec.yaml` 的 `flutter:` 段**只有** `uses-material-design: true`，**没有 `assets:` 声明** | `pubspec.yaml` |
| `lib/` 中零处引用该文件 | `grep -rn 'logo' lib` 只命中 `logout` 相关标识符 |

即：**logo 既没打进产物，也没出现在任何一屏**。这同时违反 `xconnect-dev-constraints` §5
「新静态资源 → `assets/` + 注册 `pubspec.yaml`」。

### 2.6 浅色模式语义色不达标 —— 而注释声称达标

`app_theme.dart` 的 `AppColors` 段注释写着：

> *Status semantics – must pass WCAG AA (4.5:1) on both surfaces*

在 `cardBackground #F3F4F6` 上实测（这正是主页所有卡片的底色）：

| Token | 值 | 对 card 比值 | 判定 | 用在哪 |
|---|---|---|---|---|
| `success` | `#3E8F5A` | **3.61** | ✗ | 已连接状态文字、节点 chip |
| `warning` | `#BF8A3A` | **2.76** | ✗ | 切换中状态文字 |
| `error` | `#C3655C` | **3.58** | ✗ | 错误态 |
| `download` | `#5B8DEF` | **2.94** | ✗ | 下载指标 badge 与标签 |
| `upload` | `#DA6A87` | **2.99** | ✗ | 上传指标 badge 与标签 |
| `subtleText` | `#98A1B2` | **2.36** | ✗ | 「节点列表」标签、**未连接状态文字** |
| `brand` | `#5C6BC0` | 4.42 | ✗ | 主色，勉强不过 |
| `mutedText` | `#667085` | 4.52 | ⚠ | 通过，零余量 |
| 白字 / FAB 已连接 `#3E8F5A` | — | **3.98** | ✗ | FAB 标签 14px，需 4.5 |
| 白字 / 渐变起点 `#5B8DEF` | — | **3.23** | ✗ | 添加节点按钮图标 |

**9 组不合格。** 未连接状态那行字号 24 / w700 属于大字号（阈值 3.0），`subtleText` 的 2.36 连大字号
阈值都过不了。

深色模式全部达标（最低 `subtleText` 5.44），问题**集中在浅色模式**。

### 2.7 导航选中态是 Material 默认紫

`_navigationRailTheme`（`app_theme.dart`）把选中图标与标签设为 `cs.primary` = `#5C6BC0` 靛蓝；
移动端 `NavigationBar`（`main.dart:675-690`）**完全没有主题定制**，用的是 Material 3 默认的
`secondaryContainer` 紫色药丸指示器。两端选中态视觉语言不一致，且都与 R5 相反。

### 2.8 无障碍能力（全仓统计）

| 能力 | 当前 | 说明 |
|---|---|---|
| `Semantics(…)` | **1 处** | 仅 `settings_tab_bar.dart:77` |
| `Tooltip(…)` | **0 处** | AppBar 的 `IconButton` 用的是 `tooltip:` 参数，图标按钮之外无覆盖 |
| `MediaQuery.disableAnimations` | **0 处** | 主页有 4 处 `AnimatedSwitcher` / `AnimatedSize` / `AnimatedRotation` 无条件播放 |
| `boldText` / `highContrast` | **0 处** | 未响应系统辅助功能开关 |
| `textScaler` | 4 处，**全在 `log_console.dart`** | 主页零处理 |
| 桌面可见焦点环 | 无 | |
| 裸 `GestureDetector` | **0 处** | ✅ 这一项现状良好 |

---

## 3. Token 层

### 3.1 颜色 —— Light

`XConnectColors` 字段名保持不变，改取值并新增 4 个。所有新值已实测（§10.1）。

| Token | 现值 | **新值** | 对 card 比值 | 用途 |
|---|---|---|---|---|
| `cardBackground` | `#F3F4F6` | `#F1F3F5` | — | 卡片填充（R2 主力） |
| `cardBorder` | `#E9EBEF` | `#E7EAEE` | — | **改作下沉面**，不再画边 |
| `mutedText` | `#667085` | `#4E5A65` | 6.35 | 次级文字 |
| `subtleText` | `#98A1B2` | `#5B6874` | 5.13 | 标签、未连接态 |
| `brand` | `#5C6BC0` | `#3F4BA0` | 6.93 | 主色、链接、选中指示 |
| `success` | `#3E8F5A` | `#236B3F` | 5.82 | 已连接 |
| `warning` | `#BF8A3A` | `#8A5200` | 5.74 | 切换中 |
| `error` | `#C3655C` | `#B3261E` | 5.88 | 错误 |
| `download` | `#5B8DEF` | `#1F5FBF` | 5.48 | 下行指标（见 §8.3） |
| `upload` | `#DA6A87` | `#A83A57` | 5.54 | 上行指标（见 §8.3） |
| **`ink`** 新增 | —（散落的 `#1F2937`） | `#111827` | — | **主行动实心底（R1）** |
| **`onInk`** 新增 | — | `#FFFFFF` | — | 主行动前景 |
| **`inkPressed`** 新增 | — | `#2B3441` | — | 主行动按压 |
| **`surfaceSunken`** 新增 | — | `#E7EAEE` | — | 卡内下沉块、按压态 |

`warningBanner*` 三个字段保持不变（黄底告警条是既有的独立语义，本期不动）。

### 3.2 颜色 —— Dark

深色模式对比度全部达标，**只做两处收敛**，其余不动：

| Token | 现值 | 新值 | 理由 |
|---|---|---|---|
| `cardBorder` | `#383850` | `#242A31` | 对 card 只有 1.49 —— 本来就看不见，去描边后改作下沉面 |
| `cardBackground` | `#1E1E2E` | `#191D21` | 去掉偏紫，转中性（与 `#141422` 的 surface 一同收敛） |
| **`ink`** 新增 | — | `#E7E9EA` | **反相**：深色下主行动是浅底深字 |
| **`onInk`** 新增 | — | `#0B0E11` | |
| **`inkPressed`** 新增 | — | `#C9CDD0` | |
| **`surfaceSunken`** 新增 | — | `#22272C` | |

> 主行动永远是画面里对比最强的块。浅色下是墨黑，深色下就是浅白 —— 语义一致，形态相反。

### 3.3 圆角：两档 + pill

```dart
class AppRadius {
  AppRadius._();
  static const double sm   = 8;    // 内嵌小块、下沉块
  static const double card = 16;   // 卡片、对话框、浮层、输入框
  static const double pill = 999;  // 按钮、chip、FAB、徽标、圆点
}
```

8 种取值收敛为 3 档。逐一映射：

| 现值 | 处 | → |
|---|---|---|
| `24` | 监控卡 | `card` |
| `20` | 添加节点按钮 | `pill` |
| `18` | 节点卡 `InkWell` | `card` |
| `17` | 指标 badge（34px 圆） | 改用 `BoxShape.circle` |
| `16` | dialog / cardTheme / popupMenu | `card` |
| `12` | input / elevatedButton | `card` |
| `8` | 若干小块 | `sm` |
| `999` | 已有 pill | `pill` |

**改圆角不改元素外框尺寸**，符合 §0。

### 3.4 排版：补一个 TextTheme

当前 53 处 `fontSize:` 字面量、零 `TextTheme`。**本期不改任何字号数值**，只是把现有取值
收进 `TextTheme`，让后续能统一管理：

| 语义 | 取自现有 | 用在哪 |
|---|---|---|
| `displaySmall` | 30 / w700 / -0.8 / h1.0 | 流量大数字 |
| `headlineSmall` | 24 / w700 / -0.4 | 连接状态标题 |
| `titleLarge` | 18 / w600 | 节点名 |
| `titleMedium` | 16 / w600 | 节点卡主文案、AppBar |
| `bodyMedium` | 14 / w400 | 正文、对话框 |
| `labelLarge` | 13 / w600 | 指标标签、chip |
| `labelSmall` | 12 / w500 | meta 行、导航标签 |

> 这是纯搬运：每一处 `fontSize: N` 替换成对应的 `Theme.of(context).textTheme.*`，
> **渲染结果逐像素相同**。收益是 §12 B1 那次真正的移动端放大只需要改一个地方。

### 3.5 动效

| Token | 值 | 曲线 | 现有落点 |
|---|---|---|---|
| `motionInstant` | 120ms | `easeOut` | 按压、颜色切换（新增） |
| `motionQuick` | 180ms | `easeOutCubic` | — |
| `motionStandard` | 220ms | `easeOutCubic` | 主页 4 处动画**已经都是 220ms** |
| `motionEmphasis` | 320ms | `easeOutCubic` | 对话框、菜单 |

现有取值已经统一在 220ms，只需收进 token。新增 `resolveDuration(context)`：
`MediaQuery.of(context).disableAnimations == true` 时返回 `Duration.zero`。

---

## 4. Logo 系统

### 4.1 现有 mark

三个蓝色六边形节点 + 三组双向弧形箭头，圆角方形白底 —— 网状中继 / 多节点互联的隐喻，
与产品语义（多节点安全隧道）贴合。线性笔画、**已经是单色**，非常适合 R6 的处理方式。

### 4.2 需要补的资产与注册

| 动作 | 说明 |
|---|---|
| 新增 `assets/logo_mono.svg` | 单色 `currentColor` 线性版（去掉白底方块，只留 mark），**主力资产** |
| 保留 `assets/logo.png` | 应用图标源文件（`make icon` / `scripts/generate_icons.sh` 用），**不进 Flutter bundle** |
| 新增 `assets/logo_mark_{1,2,3}x.png` | 96 / 192 / 288，SVG 不可用时兜底 |
| **在 `pubspec.yaml` 注册** | 只注册 mono + mark 三档，**逐文件声明**，不要整目录 —— 避免把 724 KB 的图标源文件打进产物 |

### 4.3 三种用法

| 用法 | 规格 | 落点 |
|---|---|---|
| **A 水印** | 单色 mark，色 `onSurface`，不透明度 **6%（浅色）/ 8%（深色）**，边长 `min(卡宽×0.42, 180)` | 主页**无节点空态**（`noNodes` 分支）的现有空白区。不新增元素、不挤压任何现有元素 |
| **B 品牌块** | 单色 mark 反相置于 `ink` 实心块内，块 24×24，圆角 `sm`，mark 占 68% | AppBar 面包屑左侧的现有 `leading` 位；About 页标题前缀 |
| **C inline 小标** | 单色 mark，色 `mutedText`，20×20，无容器 | `NavigationRail` 顶部（现有 `leading` 槽位，当前为空） |

> A 用法是本期唯一新增的可见元素。它落在**已经是空白**的区域，装饰性，须包 `ExcludeSemantics`
> 不进无障碍树 —— 因此**不需要新增 l10n key**。

### 4.4 使用规则

- 最小尺寸 16×16（低于此改用纯色圆点）
- 四周留白 ≥ mark 边长的 12%
- **禁止**：拉伸变形、加投影、旋转、给 mono 版描边、在 `brand` 底色上用原蓝色版
- 深色主题下 mono 版自动取 `onSurface`，不做单独深色资产

---

## 5. 按钮系统

### 5.1 层级定义

| 变体 | 底 | 前景 | 描边 | 圆角 | 用途 |
|---|---|---|---|---|---|
| **`ink`**（主行动） | `ink` | `onInk` | 无 | `pill` | **每屏至多一个** |
| `tonal`（次级） | `cardBackground` | `onSurface` | 无 | `pill` | 次要动作、工具栏入口 |
| `plain`（文字） | 透明 | `brand` | 无 | `pill` | 链接式动作 |
| `danger` | 透明 | `error` | 无 | `pill` | 危险动作 |

映射到现有组件，**不新增 widget、不改调用点**：`ElevatedButton` → `ink`（`_elevatedButtonTheme`
底从 `cs.primary` 改 `ink`）、`OutlinedButton` → `tonal`、`TextButton` → `plain`。

### 5.2 状态表

| 状态 | ink | tonal | plain |
|---|---|---|---|
| default | `ink` / `onInk` | `cardBackground` / `onSurface` | 透明 / `brand` |
| **pressed** | `inkPressed` | `surfaceSunken` | `brand` @12% 底 |
| hover（桌面） | `ink` @ 92% | `surfaceSunken` | `brand` @8% 底 |
| **focus**（新增） | 2px `brand` 外环，offset 2 | 同 | 同 |
| disabled | 底与前景各降至 38% α | 同 | 前景 38% α |
| loading | 前景换 18pt `CircularProgressIndicator(strokeWidth: 2)`，宽度锁定 | 同 | 同 |

按压统一 `scale 0.97` + `motionInstant`。

### 5.3 主页三处按钮的具体改法

| 元素 | 位置（不变） | 现状 | **目标** |
|---|---|---|---|
| **连接 FAB** `home_screen.dart:1329` | 右下 `Positioned(right:20,bottom:20)` | 未连接 `#1F2937` 硬编码；已连接 `#3E8F5A` 硬编码（白字 3.98 ✗） | 未连接 → `ink` / `onInk`；已连接 → `success` 新值 `#236B3F`（白字 **6.35** ✓）。两态都是 `pill`。**这是全屏唯一的 ink 块** |
| **添加节点** `main.dart:637` | AppBar actions 末位 | 蓝紫渐变 + 彩色投影 + `circular(20)` | **去渐变、去投影**，改 `tonal`：底 `cardBackground`，图标 `onSurface`，`pill`。让位给 FAB |
| **语言切换** `main.dart:601` | AppBar actions 首位 | `IconButton` 裹 `Text('中'/'EN')` | 保持 `IconButton`，前景 `mutedText`；补 `Semantics(button: true)` |

> **核心纪律：每屏至多一个 `ink`。** 设计审查第一件事就是数深色块数量。当前主页有两个视觉主角
> （渐变按钮 + FAB），改后只剩 FAB。

### 5.4 节点 ChoiceChip

`_buildNodeOptionChip`（`home_screen.dart:1169-1213`）当前用三层描边区分 active / emphasized / 普通：

| 状态 | 现状 | 目标 |
|---|---|---|
| 普通 | 底 `cs.surface` + `outlineVariant` 描边 | 底 `cardBackground`，**无描边** |
| 选中 / 高亮 | 底 `cardBackground` + `cardBorder` 描边 | 底 `surfaceSunken`，**无描边**，文字 `onSurface` |
| **运行中** | 底 `success` @12% + `success` 描边 + 8px 圆点 | 底 `success` @12%，**保留 1px `success` 描边**（§6 规则 3：状态语义边） + 圆点 |
| 圆角 | Material 默认 | `pill` |
| 命中区 | `materialTapTargetSize: shrinkWrap` | 移动端改 `padded`（§7.4） |

---

## 6. 表面与描边规则

```
需要把一块内容与背景区分开时：

  1. 首选   填充 cardBackground，无描边、无阴影
  2. 已在 cardBackground 上 → surface 或 surfaceSunken，仍无描边
  3. 例外   描边只用于「表达状态」，不用于「画边界」
            —— 运行中节点 chip 的 success 边、focus 环的 brand 边
  4. 阴影   仅用于真正浮起的层：dialog、popupMenu、FAB
```

按此规则移除：

| 位置 | 文件 | 动作 |
|---|---|---|
| 监控卡 `border` + `boxShadow` | `home_screen.dart:787-810` | 两者全删，只留填充 |
| `cardTheme` 的 `elevation: 1` | `app_theme.dart:_cardTheme` | → 0 |
| 添加节点按钮的彩色投影 | `main.dart:658-665` | 删 |
| 输入框 `enabledBorder` 描边 | `app_theme.dart:_inputDecoration` | 改 `filled` + 无边；`focusedBorder` 保留（规则 3） |
| `NavigationRail` 右侧 `VerticalDivider` | `main.dart:706` | **保留** —— 这是两个 pane 的真实边界 |

---

## 7. 图标、反馈与命中区

### 7.1 图标形态（R5）

| 场景 | 规则 |
|---|---|
| 默认 | 线性族，色 `mutedText` |
| **选中 / 激活** | **同一图标的实心版**，色 `onSurface` —— 不靠变靛蓝 |
| 主行动内 | `onInk` |
| 状态语义 | `success` / `warning` / `error`，且**必须**同时有文字或 `Semantics` 标签 |

具体到两个导航组件（**图标尺寸与导航项数量不变**）：

- `_navigationRailTheme`：`selectedIconTheme` 从 `cs.primary` 改 `onSurface` + 实心图标；
  选中标签 `onSurface` / w600；未选中 `mutedText`。
- `NavigationBar`（`main.dart:675`）：**当前零定制**，需补 `navigationBarTheme` ——
  `indicatorColor: surfaceSunken`（取代默认紫药丸）、选中图标实心 `onSurface`、
  `labelBehavior` 保持 `alwaysShow`。

### 7.2 按压反馈

| Surface | 做法 |
|---|---|
| Android | 保留 Material ripple（现状即是，无需改） |
| iOS | 补底色按压态（`surfaceSunken`，`motionInstant`） |
| desktop | hover 底色 + `motionInstant` |

现状好消息：**全仓 0 处裸 `GestureDetector`**，可点元素都走 `InkWell` / Material 组件，
反馈基础是完好的。

### 7.3 焦点环（桌面，新增）

所有可聚焦元素：2px `brand`，offset 2，圆角随元素。当前桌面端键盘导航完全没有可见焦点。

### 7.4 命中区扩大（不改视觉尺寸）

在 §0 约束下修触控问题的唯一合法手段 —— **视觉尺寸不动，命中区向已有留白扩**：

```dart
// 视觉不变，命中区 44×44
InkResponse(
  radius: 22,
  containedInkWell: false,
  child: SizedBox(width: 44, height: 44, child: Center(child: 原有内容)),
)
```

配套：`materialTapTargetSize` 按平台分叉 —— 移动端 `padded`，桌面端 `shrinkWrap`。
适用：节点 ChoiceChip（现为 `shrinkWrap`）、AppBar 语言切换键、节点卡展开箭头。

---

## 8. 主页样式映射

位置全部保持现状，只列样式变化。

### 8.1 连接状态卡 `_buildPrimaryStatusCard`

| 元素 | 现状 | 目标 |
|---|---|---|
| 卡容器 | 填充 + 描边 + 阴影 + `circular(24)` | **仅填充** `cardBackground`，`card`(16) |
| 状态圆点 10×10 | `success #3E8F5A` / `warning #BF8A3A` / `subtleText #98A1B2` | 新值 `#236B3F` / `#8A5200` / `#5B6874` |
| 状态文字 24/w700 | 同上三色，未连接态 **2.36** ✗ | 同上新值，未连接态 **5.13** ✓ |
| 节点名 18/w600 | `cs.onSurface` | 不变（15.57 ✓） |
| meta 行 12/w500 | `mutedText` 4.52 ⚠ | `mutedText` 新值 **6.35** ✓ |
| 指标 badge 34×34 | `circular(17)` 手算圆，底 色@12% | `BoxShape.circle`，底 色@12%（新色） |
| 流量大数字 30/w700 | `cs.onSurface` | 不变；字号收进 `displaySmall` |
| 底部三格数值 | 同上 | 延迟色沿用 `_latencyVisual`，色值随 §3.1 更新 |

### 8.2 节点卡 `_buildNodeSummarySection`

| 元素 | 现状 | 目标 |
|---|---|---|
| 卡容器 | 同 8.1 三件套 | 仅填充，`card` |
| `InkWell` 圆角 | `circular(18)` | `card` |
| 「节点列表」标签 12/w600 | `subtleText` **2.36** ✗ | `subtleText` 新值 **5.13** ✓ |
| 展开箭头 | `AnimatedRotation` 220ms | 不变，改走 `motionStandard`；补 `disableAnimations` 处理 |
| 节点 chip | §5.4 | |

### 8.3 数据色特例（R7 的边界）

上传 / 下载不是装饰色，是**信息编码** —— 用户靠颜色区分两条流量。因此：

- **不去色**，但两个色相都拉到 AA：`download #1F5FBF`（5.48）/ `upload #A83A57`（5.54）
- 两者色相差 ≈ 175°，在色觉障碍下仍可区分（蓝 ↔ 品红方向），且**同时有 ↓ / ↑ 图标与文字标签**，
  不单独依赖颜色
- 语义色（success / warning / error）与品牌色 `brand` 分属三套，互不复用

这是本设计系统里**唯一保留多彩的地方**，理由记录在此以免后续被「统一去色」改掉。

### 8.4 桌面 vs 移动壳层

| 区域 | 改动 | 明确不变 |
|---|---|---|
| AppBar | `_appBarTheme` 去 `surfaceTint`；面包屑 `leading` 放 §4.3 B 品牌块 | 面包屑结构、`compact` 逻辑、actions 顺序 |
| `NavigationRail`（`≥900px`） | §7.1；顶部 `leading` 放 §4.3 C inline 小标 | `labelType: all`、5 个目的地、宽度 |
| `NavigationBar`（`<900px` 且 iOS/Android） | §7.1 新增 `navigationBarTheme` | 3 个目的地、`alwaysShow` |
| 内容区 | `maxWidth: 860` 居中约束 | **不变** |
| `VerticalDivider` | 保留（§6 规则例外） | 位置 |

---

## 9. 平台差异

| 项 | iOS | Android | macOS | Windows | Linux |
|---|---|---|---|---|---|
| 主导航 | `NavigationBar`（底部，3 项） | 同 | `NavigationRail`（左侧，5 项） | 同 | 同 |
| 断点 | `< 900` 且是手机平台 | 同 | 恒为 Rail | 同 | 同 |
| 按压反馈 | 底色变化 | **Ripple**（现状保留） | hover + 底色 | hover + 底色 | hover + 底色 |
| `materialTapTargetSize` | `padded` | `padded` | `shrinkWrap` | `shrinkWrap` | `shrinkWrap` |
| 最小命中区 | 44×44 | 48×48 | 28（指针） | 28 | 28 |
| 焦点环 | — | — | **必需** | **必需** | **必需** |
| logo 水印 α | 6% / 8% | 6% / 8% | 6% / 8% | 6% / 8% | 6% / 8% |
| 深色主题 | 跟随系统 | 跟随系统 | 跟随系统 | 跟随系统 | 跟随系统（部分发行版无信号 → 回落浅色） |
| 系统托盘 | — | — | systray（Go 侧） | systray | systray |

> 桌面端的 5 项 vs 移动端 3 项导航是**既有的功能差异**（`desktopPages` / `mobilePages`，
> `main.dart:557-569`），不在本次范围内，不要「顺手对齐」。

---

## 10. 无障碍

### 10.1 新 palette 对比度实测（WCAG 2.1）

浅色，对 `cardBackground #F1F3F5`（主页所有卡片底色）与 `surface #FFFFFF` 双基准：

| Token | 新值 | 对 surface | 对 card | 判定 |
|---|---|---|---|---|
| `onSurface` | `#1C1B1F` | 16.25 | 15.57 | AAA |
| `mutedText` | `#4E5A65` | 7.06 | 6.35 | AAA |
| `subtleText` | `#5B6874` | 5.71 | 5.13 | AA |
| `brand` | `#3F4BA0` | 7.71 | 6.93 | AAA |
| `success` | `#236B3F` | 6.47 | 5.82 | AA |
| `warning` | `#8A5200` | 6.39 | 5.74 | AA |
| `error` | `#B3261E` | 6.54 | 5.88 | AA |
| `download` | `#1F5FBF` | 6.09 | 5.48 | AA |
| `upload` | `#A83A57` | 6.16 | 5.54 | AA |
| `onInk` 白 / `ink #111827` | — | 17.74 | — | AAA |
| 白 / FAB 已连接 `#236B3F` | — | 6.47 | — | AA |

深色（对 `cardBackground #191D21`）：`onSurface` 12.70、`mutedText` 8.23、`subtleText` 5.44、
`brand` 7.10、`success` 6.77、`warning` 8.10、`error` 7.62、`download` 7.14、`upload` 7.74、
`onInk #0B0E11` / `ink #E7E9EA` 15.89 —— **全部 AA 以上**。

> **最小余量 5.13 对 4.5。** 改任何文本色前必须重跑校验。

### 10.2 语义标注（纯代码，零布局影响）

现状只有 1 处 `Semantics`。主页需补：

| 元素 | 必需 |
|---|---|
| 连接状态圆点 + 文字 | 圆点包 `ExcludeSemantics`，文字已含状态词 —— **不可只靠颜色**（现状文字已在，合格） |
| 连接 FAB | `Semantics(button: true, enabled: !_isSwitchingNode)`；label 走现有 `startAcceleration` / `stopAcceleration` key |
| 流量指标 | `Semantics(label: '<标签> <数值>')`，避免读屏把 badge 图标与数字读成两段 |
| 节点 chip | `Semantics(button: true, selected: emphasized)` |
| 切换中态 | `Semantics(liveRegion: true)` —— 状态变化需播报 |
| 节点卡展开箭头 | `Semantics(button: true, expanded: _showNodeOptions)` |
| **logo 水印** | `ExcludeSemantics` —— 装饰性，**因此无需新增 l10n key** |

> 凡是需要新文案的语义标签，一律走 `context.l10n.get()` 并同时补 en / zh
> （`xconnect-dev-constraints` §2.2），且遵守审批词汇表。

### 10.3 系统辅助开关

| 开关 | 要求 | 本期 |
|---|---|---|
| 减弱动效 `disableAnimations` | 主页 4 处动画时长归零 | ✅ 纯样式 |
| 加粗文本 `boldText` | 字重 +100 | ✅ 纯样式 |
| 高对比 `highContrast` | `subtleText` 降级为 `mutedText`；恢复 1px 边界 | ✅ 纯样式 |
| 大字号 `textScaler` 200% | 需要弹性容器 | ⏸ 涉及尺寸，进 §12 |

---

## 11. 落地与验收

### 11.1 阶段拆分（每阶段一个 PR，独立可回滚，全部进 `main`）

| 阶段 | 内容 | 文件 |
|---|---|---|
| **一 token** | §3.1–3.3 颜色 / 圆角；`XConnectColors` 新增 4 字段 + `copyWith` / `lerp` 同步 | `lib/utils/app_theme.dart` |
| **二 TextTheme** | §3.4 —— 53 处 `fontSize:` 搬进 `TextTheme`，**渲染逐像素相同** | `app_theme.dart` + 各调用点 |
| **三 按钮** | §5：`_elevatedButtonTheme` 改 ink、FAB 去硬编码、添加节点去渐变去投影 | `app_theme.dart`、`main.dart:637`、`home_screen.dart:1329` |
| **四 表面** | §6：监控卡去描边去阴影、`cardTheme` elevation → 0、输入框去边 | `home_screen.dart:787`、`app_theme.dart` |
| **五 导航与图标** | §7.1：Rail 选中态改实心 + `onSurface`；新增 `navigationBarTheme` | `app_theme.dart`、`main.dart:675` |
| **六 logo** | §4：补 mono SVG、`pubspec.yaml` 逐文件注册、三处落点 | `assets/`、`pubspec.yaml`、`main.dart`、`home_screen.dart` |
| **七 无障碍** | §7.3 焦点环、§7.4 命中区、§10.2 语义、§10.3 系统开关 | 各调用点 |

### 11.2 量化验收

| 指标 | 现状 | 目标 |
|---|---|---|
| `BorderRadius.circular(字面量)` 调用点 | **34**（8 种取值） | 0（全走 `AppRadius`） |
| `fontSize:` 字面量 | **53** | 0（全走 `TextTheme`） |
| `Color(0x…)`（theme 外） | **3** | 0 |
| `Colors.*` 字面量（theme 外） | **6** | 0 |
| 浅色 WCAG AA 不合格组合 | **9** | 0 |
| 单屏 `ink` 主行动数量 | 2（渐变按钮 + FAB） | **≤ 1** |
| `LinearGradient` 使用 | 1 | 0 |
| 卡片同时用「填充+描边+阴影」 | 2 处 | 0 |
| `disableAnimations` 处理 | 0 | 主页 4 处动画全覆盖 |
| `Semantics` 覆盖（主页交互元素） | 0 | 全部 |
| `logo.png` 在 `pubspec.yaml` 注册 | **否**（违反 dev-constraints §5） | 是（mono 资产逐文件注册） |
| **元素外框位移** | — | **0 px（§0 判据）** |

### 11.3 PR 准入（沿用仓库既有 checklist）

- [ ] `flutter analyze` 零新增 issue
- [ ] `dart format .` 已应用
- [ ] `CHANGELOG.md` 更新（UI 改版属于 user-facing，中英双份 `CHANGELOG-ZH.md` / `CHANGELOG-EN.md`）
- [ ] 构建目标已实测并写进 PR 描述
- [ ] **额外**：附浅色 + 深色 × macOS / iOS / Android 的改版前后对照截图
- [ ] **额外**：overlay diff —— 前后截图叠加，验证元素外框零位移

### 11.4 测试注意

- 现有 `test/` 下是 services / sync / utils / widgets 的单元测试，**无 golden 测试** ——
  本次改版不会撞到 golden 基线，但也意味着**视觉回归只能靠人工截图对照**，
  §11.3 的 overlay diff 是唯一的自动化替代品。
- 建议新增静态守卫测试：扫描 `lib/`，断言字面量圆角与 `fontSize` 调用点为 0。
- 主题改动会影响 `test/widgets/` 下依赖颜色断言的用例，需同步核对。

---

## 12. B 层留档（超出「布局不变」，本期不做）

| # | 问题 | 建议 | 代价 |
|---|---|---|---|
| B1 | 移动端与桌面端共用同一套字号；30px 流量数字在小屏偏大，13px 标签在 iOS 偏小 | 阶段二的 `TextTheme` 落地后，按平台分叉字号表 | 全移动端重排 |
| B2 | 无间距标度：主页出现 `4/6/8/10/12/14/16/18/20/22/24` 共 11 种硬编码间距 | 建 4/8/12/16/24/32 标度 | 全屏位移 |
| B3 | 监控卡内距 `fromLTRB(22,22,22,18)` —— 22 是全仓孤例 | → 16 或 20 | 卡内元素整体位移 |
| B4 | FAB 用 `Positioned(right:20,bottom:20)` 手写定位，未走 `Scaffold.floatingActionButton`，移动端会与 `NavigationBar` 抢占底部空间 | 改用 `Scaffold` 槽位 | 移动端底部布局变化，需实机验证 |
| B5 | 内容区 `SingleChildScrollView` 底部留 120px 给 FAB —— 硬编码避让 | 随 B4 一起改 | 依赖 B4 |
| B6 | 主页固定高度元素在 200% 字号下溢出（badge 34、chip 单行） | 弹性化 | 依赖 B2 |
| B7 | 桌面 5 项 / 移动 3 项导航不一致（Help、About 在移动端不可达） | 产品决策，非样式问题 | **改导航结构，需立项** |

---

## 13. 待确认

1. **§4.3 A 的 logo 水印**是本期唯一新增的可见元素（落在无节点空态的既有空白、装饰性、
   `ExcludeSemantics` 不进无障碍树、不需要新 l10n key）。确认可做？
2. **§5.3 添加节点按钮去渐变降为 `tonal`** —— 为守住「每屏一个 ink」。这会明显降低该入口的
   视觉权重，需产品确认这是期望的（主行动应当是「开始加速」）。
3. **§3.1 `brand` 从 `#5C6BC0` 改 `#3F4BA0`** —— 品牌主色变深。若 `#5C6BC0` 是对外品牌规范里
   锁定的色值，则改为「保留品牌色用于非文本场景，文本/图标场景用加深版」的双值方案。
4. **§4.2 `assets/logo.png` 不进 Flutter bundle** —— 需确认 `make icon` /
   `scripts/generate_icons.sh` 只从文件系统读它，不依赖 Flutter 资源加载。
