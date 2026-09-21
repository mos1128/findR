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
✅ **Flutter SDK 已装好**（2026-09-21）：**3.47.5 stable / Dart 3.13.4**，
   `flutter --version` 与 `dart --version` 均实测通过。**Android SDK 仍未装**（可延后，见 7.1）。
✅ **骨架已建好**（2026-09-21）：`apps/flutter/`（Flutter app，applicationId `com.findr.app.dev`）
   + `packages/findr_core/`（纯 Dart core 包）。两边 `flutter analyze` / `dart test` 均绿，
   RN 侧 `pnpm check` **仍是 181 通过**（基线没被破坏）。
✅ **命门第 1 层已通过**：本地 FTS5 + trigram 命中中文，押在
   `packages/findr_core/test/fts5_trigram_test.dart`。**第 2 层（真机）还没做** —— 见 6.0。

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

1. **`package:sqlite3` 3.x 自带预编译 SQLite**（改用 Dart **build hooks** 打包，不再走
   `DynamicLibrary`，也不再需要任何 `*_flutter_libs` 包）—— **默认编译选项含 `SQLITE_ENABLE_FTS5`**，
   覆盖 Android / iOS / macOS / Linux / Windows。
   ⇒ 我们整套搜索可以平移，**而且各平台的 SQLite 编译选项是一致的** ——
   上游明说这是它自带 SQLite 的理由（「系统自带的库编译选项不一致、版本常常太旧」），
   正好对上我们最怕的「各平台能力不一致」。
   ✅ **L1 已实测通过（2026-09-21）**：SQLite 3.53.4 / `ENABLE_FTS5` / trigram 下 3 字以上中文命中。
   详见第 6.0 节。
   ⚠️ **`sqlite3_flutter_libs` 已废弃（版本号 `0.6.0+eol`，README 明说「什么都不做」）—— 别再用它**。
      网上大量教程还写着它，属于过时信息。
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
2. **数据库依赖只有一层**：`findr_core` 依赖 **`package:sqlite3` 3.x**，就这一条。
   它**自带预编译 SQLite**，**app 端不用再补任何 native 库依赖**。
   （此前设计的「core 用 sqlite3 + app 加 sqlite3_flutter_libs」**已作废** ——
   `sqlite3_flutter_libs` 废弃了，见 4.5。）
   好处：core 是纯 Dart ⇒ `dart test` 直接就能验库行为，**连本机的 sqlite3.dll 都不用准备**。
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

### 4.5 ✅ 数据库方案（2026-09-21 两次修订，当前口径以下面为准）

**只依赖 `package:sqlite3` 3.x（已实测：3.6.0），直接写 SQL。**

- 它用 **Dart build hooks** 把 **预编译 SQLite** 打包进应用 ——
  **默认编译选项含 `SQLITE_ENABLE_FTS5`**（还会带上 `SQLITE_ENABLE_DBSTAT_VTAB`、
  `SQLITE_ENABLE_RTREE`、`SQLITE_ENABLE_MATH_FUNCTIONS` 等）。
- 预编译覆盖 **Android（armv7a / aarch64 / x86 / x64）**、iOS、macOS、Linux、Windows、Web
  ⇒ 我们 arm64 单架构的 APK 在覆盖范围内。
- **它默认优先用自带的这份，而不是系统的那份** ⇒ 各平台行为一致。

⚠️ **两条过时信息，别再照做：**

1. **`sqlite3_flutter_libs` 已废弃**（`0.6.0+eol`，README 明说「什么都不做」）。
   `package:sqlite3` 3.x 的升级说明里写着「升级后请把这个依赖删掉」。**app 端什么都不用加。**
2. 本地验证 **不再需要手工准备 `sqlite3.dll`** —— `dart test` 会自己拉预编译库。

**`drift` 仍不引**（沿用 2026-09-21 早先的判断，理由不变）：

1. 我们有一整套**现成的 SQL 要逐字搬**（见第 3 节）—— drift 的 DSL / codegen 反而多一层翻译，
   正好把我们最省事的那条路堵上；
2. 迁移逻辑我们本来就是手写的（`user_version` 分步推进），drift 的 `MigrationStrategy` 省不了多少；
3. 少一层 codegen ⇒ 少一个 CI 步骤、少一类「生成物没同步」的故障。

**留后门**：drift 底层就是 `sqlite3`，若将来迁移或查询复杂度涨上来，随时能在其上加一层，
不影响已译好的代码结构。

⚠️ **唯一还没验的是「打包进 APK 之后」那一层**（见 6.0 的第 2 层）——
本地纯 Dart 那层 2026-09-21 已实测通过。

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

### 6.0 第一个必须验证的点（**整个迁移的命门**）

> 建一张 FTS5 表 + **trigram 分词器**，插入中文内容，
> 用 **3 个字以上**的词做 `MATCH` 查询，**必须命中**。

我们整套检索完全建立在这上面。**这一条不通 ⇒ 整个方案要重新评估。**

**验法分两层，两层都绿才算过。**

#### 第 1 层 · 本地纯 Dart —— ✅ **已通过（2026-09-21）**

押注落在 **`packages/findr_core/test/fts5_trigram_test.dart`**（跑 `dart test` 即可，约 1 秒）。
实测结果：

| 项 | 实测值 |
|---|---|
| SQLite 版本 | **3.53.4** |
| FTS 编译选项 | **`[ENABLE_FTS5]`** |
| 3 字中文 `MATCH '圆珠笔'`（库里是「蓝色的圆珠笔放在书桌抽屉里」）| **命中 1 条** |
| 2 字 `MATCH '圆珠'` | 0 条，**不抛异常** |
| 1 字 `MATCH '笔'` | 0 条，**不抛异常** |

**顺带确认了一件重要的事**：短查询是**返回空**而不是**报错** ⇒
TS 侧「≥3 字走 `MATCH`、更短的走 `LIKE` 降级」这条设计**照搬即可**，
不需要额外加 try/catch 兜底。

#### 第 2 层 · 真机 —— ⬜ **还没做**

在 App 的**自检屏**里放同一段检查（RN 版本来就有这个习惯），在真机上跑一次 ⇒
确认**打进 APK 的那份 SQLite** 同样带 FTS5。

⚠️ **别只做第 1 层就宣布命门通过。** 第 1 层验的是**我们写的 SQL 与 trigram 语法**，
第 2 层验的才是**真正要发布的那份二进制**。
（这正是铁律 5「调用失败与能力不支持必须分开判」的同类问题：得在真实的那一层上看。）

📌 依据上第 2 层风险**已经不高**：`package:sqlite3` 3.x 是**全平台同一套预编译产物**
（上游自带 SQLite 的理由就是消灭各平台编译选项不一致），所以本地那份和 APK 里那份**理论上同源**。
但「理论上」不算数 —— **第 2 层仍要实测**。

### 6.1 然后按这个顺序

1. ~~`flutter create` + 定状态管理 + 配 `sqlite3_flutter_libs`~~ ✅ **骨架已建**（2026-09-21）：
   `apps/flutter/`（Flutter 3.47.5，`--platforms=android`，applicationId `com.findr.app.dev`）
   + `packages/findr_core/`（纯 Dart 包，依赖 `sqlite3`）。`dart test` 与 `flutter analyze` 均绿。
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
| **Flutter SDK** | ✅ **已装（2026-09-21）**：**3.47.5 stable · Dart 3.13.4**，实测通过。装法见 7.1 |
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
scoop install flutter        # extras 桶，当前清单是 Flutter 3.47.5 stable
```

- ⚠️ **`scoop update *` 会推进 Flutter 版本** ⇒ CI 里务必写死具体版本号（见 4.1 末条）。

#### 7.1.1 版本锁定策略（2026-09-21 定，三层各司其职）

| 层 | 做法 | 状态 |
|---|---|---|
| **本机** | **`scoop hold flutter`** ⇒ 冻结在 **3.47.5**，连 `scoop update *` 都不动它 | ✅ 已执行 |
| **CI** | workflow 里**写死 `flutter-version: 3.47.5`**，**绝不写 `channel: stable`** | ⬜ 待加 flutter job 时一起做 |
| **仓库** | 版本号记在本文件 + README 一行；**先不引 FVM** | ✅ 本条即为记录 |

- **为什么 CI 那层比本机那层重要**：本机漂版本顶多是个别 API 报错、当场看得见；
  **CI 漂版本 = 「昨天能出包今天不能」**，且失败点混在 20 分钟的构建日志里。
  （本仓已有先例：`check.yml` / `android.yml` 都把 `node-version` 写死成 `22`，同理。）
- **FVM（`extras` 桶有 4.3.1）现在不装** —— 它是 Java 世界 sdkman/jenv 的对应物
  （`.fvmrc` 进仓库、`fvm flutter` 取代 `flutter`），但**会再下一份完整 SDK（又 3.3 GB）**。
  **等真的需要第二个版本时再引**（V2 桌面 / 需要跨版本对比回归时）。
- **`scoop install flutter@<版本>` 这条路也留着** —— 清单 URL 是版本模板，可多版本并存，
  `scoop reset flutter@3.47.5` 切换（相当于 scoop 自带的 jenv）。同样现在不需要。
- 🚫 **别用 `flutter upgrade` 升级这个 SDK**：scoop 装出来的目录里**带 `.git`**，
  `upgrade` 会把 SDK 挪到别的版本，而 **scoop 的账本上仍记着 3.47.5**，两边不一致，
  下次 `scoop update` / 卸载时会出乱子。**要换版本一律走 scoop**（`unhold` → `update`，
  或 `install flutter@<版本>` + `reset`）。

### 7.2 装完之后的实测结果（2026-09-21，用户执行 `scoop install flutter` 后核实）

**版本与体积：**

- `flutter --version` ⇒ **Flutter 3.47.5 · channel stable** · framework revision `6a19cca564`(2026-09-17)
- `dart --version` ⇒ **Dart SDK 3.13.4 (stable) · windows_x64**
- **解压后 3.3 GB**（压缩包 1.9 GB 留在 `scoop\cache\` 里，可 `scoop cache rm flutter` 回收，
  不回收也不影响使用 —— 累计约占 5.2 GB）
- ⚠️ **别把 3.3 GB 和 App 体积混为一谈**：这是**开发期工具**，装在开发机上、不进包。
  APK 里装的是**预编译 engine（按 ABI 各几 MB）+ 自己的 Dart 代码**，与 SDK 体积无关。
  App 体积只由 ① 打包哪几个 ABI ② 引入的原生库决定 —— 见第 9 节那条（现在 53 MB → 预计 20~35 MB）。

**⚠️ 一个容易误判的点：没有 `scoop\shims\flutter`，这是对的，不是装坏了。**

该清单用的是 `env_add_path: bin`（**不是**会生成 shim 的 `bin` 字段）⇒ scoop 把
`<scoop>\apps\flutter\current\bin` **直接挂进用户 PATH**。
**所以装完必须在「新开的终端」里用** —— 已经开着的终端读不到新 PATH。

**`flutter doctor` 的真实结果（只看我这边能确定的部分）：**

| 检查项 | 结果 |
|---|---|
| Flutter | ✅ 通过 |
| Chrome（web 开发） | ✅ 通过 ⇒ **`flutter run -d chrome` 可用**，不装 Android SDK 也能看 UI |
| Network resources | ✅ 通过 |
| Android toolchain | ❌ `cmdline-tools component is missing` + `ANDROID_HOME` 未设 ⇒ **预期内，可延后** |
| Proxy Configuration | ⚠️ `NO_PROXY is not set`（次要） |

⚠️ **别被「the doctor check crashed」误导**：doctor 里有三项（`Windows Version` / `Visual Studio` /
`Connected device`）在我这边报 **check crashed**，原因是**我这个沙箱把 `reg.exe` 与 `wmic.exe`
列进了程序黑名单** —— 是**沙箱的限制，不是环境的问题**。
**要那三项的真实结论，请在你自己的终端里跑一次 `flutter doctor`。**
（这正是铁律 5 的同类问题：**「检查器跑不起来」≠「能力不支持」**，得在真实的那一层上看。）

**一个小观察（不影响 V1，V2 再看）**：`flutter config --list` 里 **`enable-windowing` 报
`(Unavailable)`** ⇒ 第 2 节第 3 条说的「Flutter 3.44 多窗口落地」在 Windows stable 上可能还没开，
**到 V2 做 Windows 桌面时复核一遍**。

### 7.3 其余环境要点

- `adb` 绝对路径：`C:\Users\mos\AppData\Local\Android\platform-tools\adb.exe`
- **bash 里先 `export PATH="/usr/bin:/bin:$PATH"`**，否则 `ls` / `find` / `head` 会 command not found
- **`git push` 超过 1 分钟毫无输出 ⇒ 凭据问题**，别干等。修法：`gh auth setup-git`（已配好过）
- macOS / iOS 构建**需要 macOS 机器** ⇒ V3 那一步要么 EAS/云 Mac，要么买 Mac + $99 年费

**Flutter 相关的（2026-09-21 实测，都是踩过的）：**

- Flutter / Dart **不在** `PATH` 里（scoop 用的是 `env_add_path`，只写进新的用户环境）
  ⇒ **agent 沙箱里必须显式加**：
  `export PATH="/d/my-software/scoop/apps/flutter/current/bin:$PATH"`
- ⚠️⚠️ **沙箱里跑 `pub get` / `dart test` / `flutter analyze` 必须先把 `PUB_CACHE` 指到工作区内**，
  否则**整条命令被 SIGTERM、连输出都没有**（很容易误判成「命令写错了」或「Flutter 装坏了」）：

  ```
  export PUB_CACHE='D:\my-develop\project\other\findR\.workbuddy\tmp\pub-cache'
  ```

  原因：默认 pub 缓存在用户目录（`%LOCALAPPDATA%\Pub\Cache`），**沙箱不允许写工作区之外**。
  **用户在「自己的终端」里跑则完全不需要这一条** —— 用默认缓存即可。
- **`flutter create` 在沙箱里会在最后一步（`pub get`）被打断**，但**产物其实是完整的**
  （`lib/`、`android/`、`pubspec.yaml` 都在，只差 `.dart_tool/`）
  ⇒ **补跑一次带 `PUB_CACHE` 的 `flutter pub get` 就好，别以为要推倒重建。**
- 沙箱把 **`reg.exe` 与 `wmic.exe` 列进了程序黑名单** ⇒ `flutter doctor` 里有三项会报
  `the doctor check crashed`（Windows Version / Visual Studio / Connected device）。
  **那是沙箱限制，不是环境问题**；要这三项的真实结论，得在**用户自己的终端**跑。

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

**进度（2026-09-21 收盘）：**

- ✅ 5 个决策定案（同仓 `apps/flutter/` + 独立 Dart core 包 `packages/findr_core`；
  旧 RN 保留对照；core 用 Dart 重写按 7 步走；Riverpod；**`package:sqlite3` 3.x，不引 drift**）
- ✅ RN 版终态 push 到远端（`ceaa4f4`）
- ✅ Flutter SDK 3.47.5 / Dart 3.13.4 装好
- ✅ 骨架建好（`apps/flutter/` + `packages/findr_core/`，两边均绿）
- ✅ **命门第 1 层通过**：FTS5 + trigram 命中中文（`dart test` 可复现）

**下一步就一件事：**

1. ⬜ **命门第 2 层** —— 真机自检屏验「打进 APK 的那份 SQLite」也带 FTS5（见 6.0）

之后按 6.1 节顺序走：译 `db/`（同步写 Dart 测试）→ 译 `search/` →
译 `providers/ + parse/ + pipeline/` 跑通最小闭环 → **最后才动 UI，而且按新设计写**。

⚠️ 提醒：`packages/findr_core/lib/findr_core.dart` 目前是**空壳**（只有说明注释），
`db/ search/ ...` 这些子目录**还没建** —— 那是接下来要一块一块填的。

