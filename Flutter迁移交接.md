# Findr · Flutter 迁移交接

> **用户 2026-09-21 拍板：从 React Native (Expo) 迁移到 Flutter。**
> **本文件是新会话的第一份必读。** RN 时代的历史细节仍在 `开发交接.md`（那份不废 —— 
> 铁律、环境坑、用户口径、历史决策仍然有效；但它的「当前进度 / 下一步 / 未验证清单 / 真机端到端验证」
> 四节**已随迁移作废**，别照着做）。

---

## 0. 新会话启动顺序（照做）

1. 读**本文件**全文
2. 读 `需求.md` —— **产品规格，最高权威**
3. 读 `技术设计.md` —— 数据模型、算法、判定标准
4. 按需读 `packages/core/src/` 的 TS 实现 —— **它就是规格说明书，是"要翻译的东西"**
5. 核对第 4 节的 5 个决策 —— **已于 2026-09-21 全部定案，直接照做即可**（别再重新讨论）
6. 再按第 6 节的 V1 路线开工

✅ **第 8 节那件事已完成**（RN 版终态已于 2026-09-21 push 到远端 `ceaa4f4`）。
⬜ **本机 Flutter SDK 待装**（必装，见第 7 节；装法已在本机核实）。

---

## 1. 用户拍板的路线（2026-09-21，原话转述）

> 「第一版先出安卓端，然后第二版再出 win 端，然后第三步再出 macOS 和 iOS」

| 版本 | 平台 | 定位 |
|---|---|---|
| **V1** | **Android** | 先跑通整条链路，验证技术选型 |
| **V2** | **Windows** | 桌面第一站 |
| **V3** | **macOS + iOS** | Apple 系一起（都要 Mac 构建，正好一批做） |

**节奏是「一版一版出」，不是一次全上。每版都要能独立跑通、能出包。**

- **Linux**：用户提过要覆盖，但**没排进这三版** —— 放最后，别提前做。
- **鸿蒙**：靠**卓易通**装安卓包，**不为它做任何改动**。
- **UI 重构**：用户此前一直想做 UI 重构。**换成 Flutter 后，UI 重构直接在 Flutter 里做** ——
  这意味着**没有"把旧界面搬过去"的包袱**，可以直接按新设计写。
  （这是本次换栈顺带白拿的一个好处，别浪费：不要先照抄 RN 的界面。）

---

## 2. 为什么换（结论 + 证据，**别再重新调研**）

**一句话**：用户要「六端 + 界面一套代码 + 体积小」，**只有 Flutter 同时给前两项**。

硬证据（本轮都已核实，完整出处见 `.workbuddy/memory/2026-09-21.md`）：

1. **`sqlite3_flutter_libs` 默认带 FTS5**，覆盖 Android / iOS / macOS / Linux / Windows
   ⇒ 我们整套搜索可以平移（**但 trigram 分词器必须实测，见第 6 节**）
2. **Canonical 于 Google I/O 2026 正式接管 Flutter 桌面**（Win/macOS/Linux 的 lead maintainer
   + strategic steward）。Canonical 自 2021 年把 Flutter 定为 Ubuntu 桌面应用默认选择，
   Ubuntu 应用中心 / 固件更新器都是 Flutter 写的 ⇒ **桌面有了专属资源方，是结构性信号**
3. **Flutter 3.44（2026-06）**：多窗口支持落地、**Windows 走真 Win32**（不是 UWP，可用 Fluent
   那套亚克力/hover）、跨平台 popup/tooltip/dialog 原语
4. **Material / Cupertino 正从 core SDK 抽成独立包** ⇒ **框架升级不再强制连带 UI 破坏性变更**
   （这条对"要重构 UI"的我们意义最大）
5. `camera_desktop` 已到 **1.2.1**（Linux GStreamer+V4L2 / macOS AVFoundation /
   Windows Media Foundation，枚举·预览·拍照·录像全有）
6. **体积**：我们 RN 的安卓包 **53MB**（已经是 arm64 单架构）→ Flutter 预计 **20~35MB**
   （引擎固定成本 4~8MB）。**桌面 Flutter 是 30~80MB，比 Tauri 差一档 —— 这是已知取舍**

**已评估并排除的方案**（别重开这个话题）：

- **Tauri 2**：体积最好（3~10MB）但**三套 WebView 渲染不一致**（Win WebView2 / macOS WKWebView /
  Linux WebKitGTK），且移动端三个缺口：相机只有官方插件且仅 iOS/Android、录音只有 0.1 版社区包、
  **安全存储官方无解**（stronghold 被维护者明确说 v3 移除）⇒ 只适合当桌面壳
- **KMP + Compose Multiplatform**：也能六端，但 Kotlin 生态更年轻，团队无底子
- **.NET MAUI**：无 Linux 官方支持
- **Electron**：无移动端，体积 100~300MB

**换栈解决不了的两件事**（先记住，别期待）：
- **iOS 的卡点是 Mac + $99/年**，Apple 的规则，与语言无关
- **鸿蒙**：Flutter-OH 比 RNOH 好（5 条版本线、262 个已适配库、出 `.hap`），但**也是社区/华为线**，
  不是 Flutter 官方

---

## 3. 迁移的真实工作量（2026-09-21 实测）

| 模块 | 文件 | 行数 | 迁移方式 |
|---|---|---|---|
| `packages/core/src` | 42 | **5,429** | **翻译成 Dart**（逐块，用测试验收）|
| `packages/core/test` | 22 | **3,773** | **近 1:1 译成 Dart 测试 = 验收网** |
| `apps/mobile/src` | 27 | **4,692** | **重写**（Flutter widget）|
| ├ 其中 `platform/` | 6 | 913 | 重写（换 Flutter 插件）|
| └ 其中 `capture/` | 7 | 821 | 重写 |
| **合计** | **91** | **13,894** | |

**⚠️ 可以直接逐字搬的两样（千万别重写、别"优化"）：**

- `packages/core/src/prompts/templates.ts` —— **纯字符串的提示词模板**，逐字复制过去
- **所有 SQL 语句**（在 `db/schema.ts` 与各 repository 里）—— **语言无关**，逐字复制

**迁移面**：26 个依赖，其中 **17 个 `expo-*` 模块**要逐个找 Flutter 替代。

**这不是"重新设计"，是"翻译 + 换壳"。** 有 181 个用例当验收网，译错了会立刻被抓住 ——
所以**迁移风险比行数看起来低**。

⚠️ 有个工具迁移后**没用了**：`.workbuddy/tools/probe-hbc-strings.py`（解析 Hermes 字节码字符串表）
是 RN 专有的（Hermes 是 RN 的 JS 引擎）。**Flutter 是 AOT 编译，没有 Hermes，这个工具作废**，
别再找它。但 **APK 拆解手法**（用 Python `zipfile` 按 `compress_size` 聚合）**仍然有用**。

---

## 4. 开工前的 5 个决策 —— ✅ **已于 2026-09-21 全部定案**

**这 5 个已经定了，别再重新讨论。** 4.1 / 4.2 由用户拍板，4.3 / 4.4 / 4.5 按推荐执行。

### 4.1 ✅ Flutter 工程放哪？—— **同仓 `apps/flutter/`**（用户 2026-09-21 定）

- 迁移期最大的需求是**随时对照 TS 源码** —— 同仓最方便，改一行 TS 就能旁边看 Dart
- **旧 RN 版还能继续出货**（万一 Flutter 卡住，有退路）
- `.github/workflows/` 里**加一个 flutter job，老的 android job 先留着**（别急着删）

**推荐目录结构（用户 2026-09-21：「按最佳实践来」）**：

```
findR/
├─ apps/
│  ├─ mobile/                    ← 旧 RN 版【保留，只读对照，不再改】
│  └─ flutter/                   ← V1 主工程（含 android/ windows/ macos/ ios/ 子目录）
│     ├─ lib/
│     │  ├─ ui/                  ← 新设计，**不照抄 RN 界面**
│     │  └─ platform/            ← 相机 / 录音 / 安全存储 / 文件 / 分享（Flutter 插件实现）
│     ├─ test/                   ← widget 测试
│     └─ pubspec.yaml            ← 用 path 依赖引用 packages/findr_core
├─ packages/
│  ├─ core/                      ← 旧 TS core【保留，它就是要翻译的规格说明书】
│  └─ findr_core/                ← 新 Dart core（**纯 Dart，零 Flutter 依赖**）
│     ├─ lib/
│     │  ├─ db/                  ← schema + 迁移 + repository
│     │  ├─ search/              ← FTS5 检索 + 打分
│     │  ├─ providers/           ← 模型 HTTP 调用
│     │  ├─ parse/               ← 手写校验（替代 zod）
│     │  ├─ pipeline/            ← 录入流程编排
│     │  ├─ backup/              ← .findrpack 导出/导入
│     │  ├─ prompts/             ← templates 逐字搬过来
│     │  └─ settings.dart
│     ├─ test/                   ← 181 个用例译到这里
│     └─ pubspec.yaml
└─ .github/workflows/            ← flutter.yml（新增）+ android.yml（老 job，先留着）
```

**三条关键设计点（别改）：**

1. **Dart core 做成独立 package，不要塞进 app 的 `lib/` 下** —— 它是纯 Dart，
   可以用 `dart test` 直接跑，不必起 Flutter 环境、不被 widget 测试拖慢；
   **V2/V3 桌面版复用同一个 core**，不用复制；也与现有 `apps/` + `packages/` 结构对称。
2. **依赖倒置**：`findr_core` 只依赖 **`sqlite3`**（纯 Dart FFI 包），
   **不依赖 `sqlite3_flutter_libs`**；`sqlite3_flutter_libs` 由 `apps/flutter` 依赖，
   它唯一的职责是「**把带 FTS5 的 native sqlite 打进各平台**」。
   （这是 drift 官方推荐的分层法，也让 core 的可测试性最大化 —— 纯 Dart 测试能直接验库行为。）
3. **名字用 `findr_core` 而不是 `core_dart`** —— Dart 包名必须 snake_case，
   且这样能与 `packages/core`（TS 老版）一眼区分。

**另外两条工程约定**：
- `.gitignore` 用 Flutter 工程自带的（`flutter create` 会生成），**别把 `build/`、`.dart_tool/` 提交进来**；
- CI 里的 Flutter 版本号**写死成与本地相同的具体版本**（不要写 `channel: stable`）——
  否则将来 stable 前进会造成「本地过、CI 挂」这种最难查的差异。

### 4.2 ✅ 旧 RN 项目怎么处理？—— **保留，不删**（用户 2026-09-21 定）

- 它是迁移期的**参照实现**，也是回滚路。
- 用户原话：「旧版保留方便对照」。等 **V1（安卓）在真机上跑通并验收过**，再考虑归档。

### 4.3 ✅ core 怎么处理？（唯一没有捷径的一件）

**没有成熟方案让 Dart 调用 TS core**（Dart 调 JS 要么嵌引擎、要么 core 编 WASM，都不成熟且更重）。
所以 **core 必须用 Dart 重写**。但**按块译、每块用对应测试验收**，别一口气译完。

建议顺序（**从底层往上，依赖少的先做**）：

1. `db/schema.ts` + 迁移 + `db/driver.ts`（那个同步接口 → Dart 抽象类/接口）
2. `db/repository.ts`（CRUD）
3. `search/`（FTS5 检索 + 排序打分）
4. `providers/`（模型 HTTP 调用）
5. `parse/`（zod 校验）
6. `pipeline/`（录入流程编排）
7. `backup/`（导出/导入打包）

⚠️ **`zod` 在 Dart 没有等价物**：建议手写校验函数，或 `json_serializable` + 手写约束。
**不要为了"对齐 zod"引入一个重 ORM/校验框架。**

### 4.4 ✅ 状态管理选型 —— **Riverpod**

- 当前 Flutter 主流，编译期安全、好测、不依赖 `BuildContext`
- 备选：Bloc（更结构化、更重）、Provider（更旧）

### 4.5 ✅ 数据库方案（2026-09-21 修订，**取代此前「倾向 drift」的写法**）

**必装（app 侧）**：`sqlite3_flutter_libs` —— 把**带 FTS5 的 native SQLite** 打包进各平台。
（按 4.1 的分层，它只归 `apps/flutter`，**不进 `findr_core`**。）

**core 侧**：`sqlite3`（纯 Dart FFI 包），**直接写 SQL**。

**`drift` 先不引。** 理由：

1. 我们有一整套**现成的 SQL 要逐字搬**（见第 3 节）—— drift 的 DSL / codegen 反而多一层翻译，
   正好把我们最省事的那条路堵上；
2. 迁移逻辑我们本来就是手写的（`user_version` 分步推进），drift 的 `MigrationStrategy` 省不了多少；
3. 少一层 codegen ⇒ 少一个 CI 步骤、少一类「生成物没同步」的故障。

**留后门**：drift 底层就是 `sqlite3`，若将来迁移或查询复杂度涨上来，随时能在其上加一层，
不影响已译好的代码结构。

⚠️ 但**第一件事仍然是验证 FTS5 + trigram 真可用**（见第 6 节，可在本地 30 秒验完）。

---

## 5. 现有资产清单（新会话必须知道它们存在）

### 5.1 六份权威文档（口径互相牵连，**改一处要 grep 全捞**）

| 文件 | 作用 |
|---|---|
| `需求.md` | **产品规格，最高权威** |
| `技术设计.md` | 数据模型、算法、判定标准 |
| `场景分析.md` | 各字段的使用场景 |
| `prompt设计.md` | 提示词设计（对应 `templates.ts`）|
| `测试计划.md` | 验收标准 |
| `开发交接.md` | RN 时代历史与铁律（**本文件的前身**）|

### 5.2 TS core 的关键文件（= 要翻译的规格说明书）

- `db/schema.ts` —— 建表 + 迁移。**⚠️ 文件顶部写了"SQLite 删列必须重建整张表"等硬约束，先读它**
- `db/repository.ts` —— 全部 CRUD
- `search/inventory.ts` —— L3 整库清单 + 相关性打分（`INVENTORY_POOL = 2000`；`scoreCard` 字段权重
  entity 6 / tags 4 / category 3 / path 2 / body 1，≥4 字 ×2；**全 0 分时退化回 `created_at DESC`**）
- `search/` 其余 —— L1（FTS5 本地检索）/ L2 + 意图路由
- `pipeline/capture.ts` —— 录入流水线（P1/P2 解析、重试、状态机）
- `providers/anthropic.ts` —— 模型调用。**认证：默认 `authorization: Bearer`，仅 401/403 时
  自动改用 `x-api-key` 重试一次**（这是第二十版定的，别改回去）
- `backup/` —— `.findrpack` 格式 = `magic "FINDR"(5B) + 版本 u16(=1) + 标准 ZIP`，**明文不加密**
  （**界面上必须明说不加密** —— 页面红条 + 导出前确认框，这是唯一防线）
- `settings.ts` —— 设置项的**唯一权威定义**（`SETTINGS_KEYS`）。
  **API Key 只进系统安全存储，永不进备份**；`settings_public` 白名单是机密性的唯一屏障

### 5.3 数据库现状（迁移必须复刻）

- **FTS5 + trigram 分词器**（≥3 字的中文走 `MATCH`；更短的走 `LIKE` 降级）
- 表：`cards` / `locations` / `categories` / `aliases` / `settings` / （FTS 影子表）
- `cards.needs_confirm` 列**保留但已停止读写**（第二十版删「待确认」功能时有意留下的）
  ⇒ **Dart 侧建表可以不建这一列**，但**导入老 `.findrpack` 时要能忽略它**

### 5.4 出网的唯一出口

**App 只发两种请求**：① 送内容给模型理解；② 送音频去转写。
**地址都是用户自己在设置页填的 `baseUrl`。没有我们的服务器、没有账号体系、没有登录、没有云同步。**
这是个**本地优先的单机应用** —— 迁移时**别引入任何后端**。

---

## 6. V1（Android）的第一步 —— 具体做什么

### ⚠️ 6.0 第一个必须验证的点（**整个迁移的命门**）

> 在 Flutter 里建一张 FTS5 表 + **trigram 分词器**，插入中文内容，
> 用 **3 个字以上**的词做 `MATCH` 查询，**必须命中**。

我们整套检索完全建立在这上面。`sqlite3_flutter_libs` 官方说"默认带 FTS5"，
**但 trigram 要实测确认**（trigram 分词器是 FTS5 内置的，SQLite 3.34+ 起有 —— 理论上跟着 FTS5 一起来，
但**必须实测，不能假设**）。

**这一条不通 ⇒ 整个方案要重新评估。** 先做它，别先写别的。

**验法分两层，两层都绿才算过**（2026-09-21 补充）：

1. **本地（约 30 秒）** —— 在 `packages/findr_core` 里写一个**纯 Dart 测试**：用 `sqlite3` 包打开本机
   的 SQLite（Windows 上放一个 SQLite 官方 `sqlite3.dll`，**官方 Windows 发行包已含 FTS5**），
   建 `USING fts5(..., tokenize='trigram')` 表、插中文、做 3 字以上 `MATCH` 查询。
   绿了 ⇒ 说明**我们写的 SQL 与 trigram 语法本身没问题**。
2. **安卓侧（真机）** —— 把同一段检查放进 App 的**自检屏**（RN 版本来就有这个习惯），
   在真机上跑一次 ⇒ 确认 `sqlite3_flutter_libs` 打进 APK 的那份 SQLite，
   在 **Android 的编译配置下**同样带 FTS5。

⚠️ **别只做第一层就宣布通过** —— 第一层验的是 SQL 语法，第二层验的才是**真正要发布的那份二进制**
（这正是铁律 5「调用失败与能力不支持必须分开判」的同类问题：得在真实的那一层上看）。

### 6.1 然后按这个顺序

1. `flutter create`（在 `apps/flutter/`）+ 定状态管理（Riverpod）+ 建 `packages/findr_core`
   + app 配 `sqlite3_flutter_libs`、core 配 `sqlite3`（**不引 drift**，见 4.5）
2. **译 `db/` 那一层**（schema + 迁移 + repository），**同步把对应的 Dart 测试写出来**
3. **译 `search/`** —— 重点验证：中文检索能命中、**排序打分结果与 TS 版一致**
4. 译 `providers/` + `parse/` + `pipeline/`，跑通「拍照/打字 → 入库 → 检索」最小闭环
5. **最后才动 UI**（而且按新设计写，别照抄 RN 的界面）

**验收方式**：把 TS 侧的用例逐一译成 Dart 测试，**绿了才算译对**。
这是一个**可以独立验证的迁移** —— 别靠"看起来对了"。

---

## 7. 环境现状与「SDK 要不要装本地」（本机实测，2026-09-21）

| 项 | 状态 |
|---|---|
| **Flutter SDK** | ⬜ **未装 —— 但必须装**（理由见 7.1）。**订正**：scoop 的 `extras` 桶里其实有 flutter 清单，此前「scoop 里也没有」的说法不准 |
| **Android SDK** | ⬜ **未装，可以先不装**（`ANDROID_HOME` 为空；`%LOCALAPPDATA%\Android` 只有 platform-tools）|
| **出包方式** | ✅ **仍走 CI**（`mos1128/findR` 的 GitHub Actions，加一个 flutter job）|
| 本机已有 | Node 22 / pnpm / Python 3.13 / `gh` CLI（**已登录**）/ `adb`（见下，不在 PATH）/ **scoop** |

### 7.1 为什么 Flutter SDK 必须装（2026-09-21 用户提问后定案）

**「出包」这一半确实可以继续全交 CI，但「验收」这一半不行。**

- **可以交给 CI 的**：`flutter build apk` 跑在 GitHub Actions 上（用 `subosito/flutter-action`），
  本机不需要 Android SDK。这一点和 RN 时代一样，**不变**。
- **不能交给 CI 的**：本次迁移的核心手段是「**逐块翻译 + 181 个用例当验收网**」，
  也就是 **改一行 → 立刻 `flutter test` 看有没有译错**。这件事必须在本机秒级完成。
  没有本地 SDK ⇒ 每轮「改一行」都要 push → 等 20+ 分钟 CI → 翻日志；181 个用例走一遍，
  时间全消耗在等构建上。
- **命门本身也要本地验**：第 6.0 节那条 FTS5 + trigram 是一次**约 30 秒的本地实验**，
  放 CI 里就是 20 分钟一轮。
- 第 9 节末尾那条「**别在没有设备反馈的情况下假定 UI 是好的**」—— 这次 UI 是重写，更需要本机跑。

**结论：Flutter SDK 必装；Android SDK 可以等 V1 要上真机时再装。**

| 想做的事 | 要装什么 | 大概体积 |
|---|---|---|
| 写 Dart、跑 181 个测试、验 FTS5/trigram | **只要 Flutter SDK**（自带 Dart + analyzer + test runner）| ~1GB，约 10 分钟 |
| 本机出 APK / 连真机 `flutter run` | 再加 Android SDK + JDK | ~5GB |
| 只想看 UI 效果、又不想装 Android SDK | `flutter run -d chrome`（纯 UI 可用；**相机 / 录音 / 钥匙串等插件在 web 上不可用**）| 0 |

**装法（本机已核实）** —— scoop 的 `extras` 桶里就有，一条命令：

```
scoop install flutter        # extras 桶，当前清单是 Flutter 3.47.4 stable
```

- 想要「把 SDK 版本钉进仓库、与 CI 严格对齐」再考虑 `scoop install fvm` + `fvm use <版本>`；
  现阶不必，FVM 随时可加。
- ⚠️ **`scoop update` 会推进 Flutter 版本** ⇒ CI 里务必写死具体版本号（见 4.1 末条）。

### 7.2 其余环境要点

- `adb` 绝对路径：`C:\Users\mos\AppData\Local\Android\platform-tools\adb.exe`
- **bash 里先 `export PATH="/usr/bin:/bin:$PATH"`**，否则 `ls` / `find` / `head` 会 command not found
- **`git push` 超过 1 分钟毫无输出 ⇒ 凭据问题**，别干等。修法：`gh auth setup-git`（已配好过）
- macOS / iOS 构建**需要 macOS 机器** ⇒ V3 那一步要么 EAS/云 Mac，要么买 Mac + $99 年费

---

## 8. ✅ 迁移前那件事：RN 版终态已 push（2026-09-21 完成）

**已办完，不用再做。** 用户 2026-09-21 明确同意后执行：

```
3aead1d..ceaa4f4  main -> main        ← 6 个提交，已推到 origin/main
```

远端与本地 HEAD 均停在 **`ceaa4f4`**（已用 `git ls-remote origin main` 核对一致）。
RN 版终态已固定到远端 —— 它是迁移期的**参照实现**，也是**回滚路**。

**几条 git 现状（2026-09-21 实测，别重复排查）**：

- **`.git/refs/remotes/origin/` 缺失** ⇒ `git status` 显示 `[gone]`、
  `git log origin/main..HEAD` 报 `unknown revision`。
  **这不影响 push 与出包** —— 已实测确认 **`refs/heads` 与 `refs/tags` 都能正常写入**
  （打 tag 是出包链路的关键，可放心；push 走 refspec，不依赖这个引用）。
- ⚠️ **但别在这个引用上耗时间**：**当前沙箱环境里它建不起来** —— `git fetch origin` 会报
  `new branch main -> origin/main`、`FETCH_HEAD` 也确实写了，可 `.git/refs/remotes/origin/main`
  就是不落盘；连 `git update-ref` 都返回 0 却无效，手动 `mkdir` 出的目录会被回滚。
  **要修就在用户自己的终端里跑一次 `git fetch origin`**，一条命令的事。
  **核对远端可以直接用 `git ls-remote origin main`，不需要那个引用。**
- 远端仓库 `mos1128/findR` **仍在、可达**；**tag 共 17 个**，最新到 `apk-m1-fix12`。
- 桌面 APK：`findr-apk-m1-fix12.apk`（**桌面上还有 fix11，建议删掉免得装错**）

---

## 9. 十二条铁律（从 RN 时代继承）

> ⚠️ **这一节与 `开发交接.md` 第 0 节是同一份，改一处必须同步另一处。**
> 每一条都真实踩过，代价很大。**这些与语言无关，迁到 Flutter 照样成立。**

1. **文档改一处要 grep 全捞**（字段清单散在六份 md 里）
2. 「看着正常但点不动 / 看不到」⇒ 先想**层叠遮挡**（`position:absolute` / `Modal` / `zIndex`）
3. 「划不动」是**另一类** ⇒ 先看有没有滚动容器
4. **动数据库必须先写测试押着，再上真机**
5. **「调用失败」与「能力不支持」必须分开判** —— 判据落在「HTTP 层是否被接受」，
   不是「内容是否如期返回」。下结论前先怀疑自己的请求参数
6. **把三态结论压成布尔下发时，想清楚第三态映射到哪边，并选代价小的那一边**：
   false 的代价是关掉用户的功能，true 的代价只是白试一次 ⇒ **拿不准就往 `true` 偏**
7. **探测项只许覆盖真正在用、且能改变行为的能力** —— 加之前先问：
   **它不通过时，系统会因此少做什么？** 答不上来就别加
8. **截断之前先想清楚「按什么排序」** —— 顺手拿「最近」当「最相关」，
   库一大就会把最该出现的那条截在名额之外。**改排序时顺带想一遍退化情形**
9. **功能退役时，优先「保留列、只摘读写两侧」，不要动 schema** ——
   SQLite 删列必须重建整张表，而 `NOT NULL DEFAULT 0` 的残留列不写不读、零成本
10. **推送 / 打包前必须停下来，等用户明确确认「没有要改的了」**（用户 2026-09-21 明确要求）：
    一次 CI 要等 20+ 分钟，别让已触发的构建白白占掉用户一轮等待
11. **同一文件的多个 Edit 不要并行发**，会丢写（非重叠的改动也会）—— 同文件一律串行，改完 grep 核对
12. **用户是真实使用者**（在真机上天天用），**他的反馈常带截图、多数时候是对的** ——
    先相信他，再去读代码，别先假设他填错了

**另外两条「不要做的事」**（RN 时代定的，迁移后照样适用）：
别在没有设备反馈的情况下假定 UI 是好的；**别卸载 App 再装**（会清库 ——
Flutter 版也一样，用户的数据在库里）。

---

## 10. 用户画像与协作偏好（**读这段，能让沟通少绕很多弯**）

- **他不懂技术**（原话：「我不是太懂技术」）⇒ **讲结论要通俗、要打比方**，别堆术语；
  他会连续追问到弄明白为止，这是正常的，别嫌烦
- **他很在意体积** —— 拿自己那个 10MB 的 Tauri 网关当证据来反问过我
- **他也想在意外观一致性** —— 这是他愿意换 Flutter 的主因
- **他要覆盖全部平台**：Win / macOS / Linux / Android / iOS
- **他决策果断**：想清楚就拍板，拍板后不喜欢反复（比如「先不改 ML Kit」说了就不再提）
- 他会**打断**你（问了一半改主意）—— 遇到就顺着新的来，别强行把旧问题讲完

**桌面那三份给他看的文档**（`C:\Users\mos\Desktop\findr-功能全景.md` / `-场景手册.md` / `-测试清单.md`）：
内容描述的是 **RN 版**的行为。**产品行为不变（需求没变）所以大体仍成立**，
但**凡涉及界面与操作路径的描述都要按 Flutter 版逐条重校**。
出包后要**刷标题与包名到新 tag**（这是老规矩）。

---

## 11. 一句话总结这一轮（2026-09-21 收盘）

**方向已定：RN → Flutter，一版一版出（安卓 → Windows → macOS/iOS）。**

- **5 个决策全部定案**：同仓 `apps/flutter/` + 独立 Dart core 包 `packages/findr_core`；
  旧 RN 保留对照；core 用 Dart 重写（按 7 步从底层往上）；Riverpod；
  `sqlite3` + `sqlite3_flutter_libs`，**不引 drift**。**别再重开讨论。**
- **RN 版终态已 push 到远端**（`ceaa4f4`），参照实现与回滚路都保住了。

**现在只剩两个动作就能开工：**

1. **装 Flutter SDK** —— `scoop install flutter`（**必装**；Android SDK 可延后，出包仍走 CI。
   理由见 7.1：出包能给 CI，但「改一行 → 跑 181 个测试」的验收必须在本机）
2. **验命门** —— FTS5 + trigram，**本地 30 秒 + 真机各一次**（见 6.0）

之后按 6.1 节顺序走：`flutter create` → 译 `db/`（同步写 Dart 测试）→ 译 `search/` →
译 `providers/ + parse/ + pipeline/` 跑通最小闭环 → **最后才动 UI，而且按新设计写**。

