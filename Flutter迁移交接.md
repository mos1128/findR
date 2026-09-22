# Findr · Flutter 迁移交接

> **用户 2026-09-21 拍板：从 React Native (Expo) 迁移到 Flutter。**
> **本文件是新会话的第一份必读，也是迁移的唯一权威。**
> RN 时代历史仍在 `开发交接.md`（**不废** —— 铁律、环境坑、用户口径、历史决策仍有效）；
> 但它的「当前进度 / 下一步 / 未验证清单 / 真机端到端验证」四节**已随迁移作废**，别照着做。

---

## 0. 新会话启动顺序（照做）

1. 读**本文件**全文
2. 读 `需求.md` —— **产品规格，最高权威**
3. 读 `技术设计.md` —— 数据模型、算法、判定标准
4. 按需读 `packages/core/src/` 的 TS 实现 —— **它就是规格说明书，是"要翻译的东西"**
5. 从 **§6.2 的进度**接着做（§4 那 5 个决策**已全部定案，别再重新讨论**）

### 0.1 当前状态快照（2026-09-22）

| 项 | 状态 |
|---|---|
| 5 个开工决策 | ✅ 定案（§4）|
| RN 版终态 | ✅ 已 push 到远端 `ceaa4f4`（参照实现 + 回滚路）|
| Flutter SDK | ✅ 3.47.5 stable / Dart 3.13.4；本机已 `scoop hold` 冻结版本（§7）|
| 骨架 | ✅ `apps/flutter/`（applicationId `com.findr.app.dev`）+ `packages/findr_core/` |
| **命门（FTS5 + trigram）** | ✅ 第 1 层（`dart test`）· ✅ 中间层（`flutter test`，Flutter 工具链下 native assets 真编出了 SQLite）· ✅ **第 2 层（真机，2026-09-22 用户实测：自检两组全绿）** ⇒ **三层全部通过，整套检索方案成立** —— 见 §6.1 |
| **core 翻译** | ✅ **约 5,394 / 5,429 行 ≈ 99.4%**（全局 39%，§6.2）—— `db/` ✅ · `search/` ✅ · `parse/`+`prompts/` ✅ · `providers/`+`settings`+`util/` ✅ · `pipeline/`+`cards/`+`media/` ✅ · **`backup/` ✅**；**剩下的 35 行只是 TS 的 `src/index.ts` 桶文件**（Dart 用一个 `findr_core.dart` 代替）⇒ **core 实质译完** |
| **应用层接线** | ✅ **7 个模块全写完**（约 1,000 行）：`app_paths` · `db` · `media` · `device_selfcheck` · `secure` · `backup` · `runtime` —— 见 §6.3。**UI 之前再无接线欠账** |
| 自检屏（真机载体） | ✅ 分两组：**核心**（FTS5 命门，优先跑在真实库文件上）+ **设备层**（PRAGMA / 外键 / 嵌套事务 / 媒体往返 / 打包往返）。**入口已从 `main.dart` 挪到「设置 → 维护」**（`main.dart` 的 `home` 现在是记忆流主页）⇒ **APK 装好，进设置点「自检」即可验命门第 2 层** |
| 验收网 | `dart test` **291 通过** · `flutter test` **83 通过** · `dart analyze` / `flutter analyze` 均无问题；RN 侧 `pnpm check` **181 passed / 2 skipped**（基线未破）|
| `findr_core` 依赖 | `sqlite3 ^3.6.0`（DB）+ **`http ^1.2.0` / `http_parser ^4.0.0`（`providers/` 联网，对应 TS 的 `fetch`）**|
| app 依赖 | `findr_core` · `path_provider` · `flutter_riverpod` · `http` · `http_parser` · `flutter_secure_storage` · `share_plus` · `file_picker` · `package_info_plus` · **`image`**（压缩到 WebP）· **`image_picker`**（拍照/相册）· **`record`**（录音，m4a/AAC）· **`audioplayers`**（回放）· **`connectivity_plus`**（无网提示）|
| CI flutter job | ✅ **已加**：`.github/workflows/flutter.yml`（`checks` 作业 + `apk` 作业；**版本写死 3.47.5**）。`checks` 已实测全绿；`apk` **已出包并发布 `flutter-dev-latest`**，且每次都对**产物本身**断言 `lib/arm64-v8a/libsqlite3.so` 含 `fts5`/`trigram`（第九轮实测：**22.1MB**；`fts5` 出现 **38** 次、`trigram` **1** 次）|
| **界面本身** | ✅ **已全部写完**（22 个文件）：`theme/tokens` · `ui/{kit,media_view,card_row,audio_player}` · `state/memory_stream` · `capture/{text_file,composer,image_compress,photo_picker,recorder,submit}` · `platform/network` · `screens/{memory_stream,card_detail}` + `screens/settings/`（5 屏）。**没照抄 RN**（§6.3）。**拍照 / 连拍 / 相册 / 长按录音 / 音频回放 / 全屏相册左右滑全部接上**，`flutter test` 从 8 涨到 **83** |

**离「MVP 能正式发」还差什么（2026-09-22 逐条核实，**别再凭印象答这个问题**）**：

| 项 | 状态 |
|---|---|
| MVP 功能面（`需求.md` §十一 那 8 条）| ✅ **已逐条核实齐了**：拍/语音/文本/文本文件录入 · 专用 ASR · desc+结构化字段可编辑 · 预设+自定义分类 · L1+L2+L3 · 纠错编辑闭环 · 明文导出导入（两道闸）· 模型配置层。连细节都在（L3 三档 `picks/maybe/missing`、`未分析` 角标 + 补分析、`待转写` + 批量补转写、L1「已放宽条件」提示）|
| 命门 + 真机自检 | ✅ 已过（§6.1，用户实测两组全绿）|
| **真机验收 16 步** | ⚠️ **只走了第 1 步**（自检）+ 竖拍照片方向 + 相册左右滑。`测试计划.md` §三 第 **2~16** 步**一步都没走** ⇒ **这是当前最大的一块** |
| UI 重构一版 | ⬜ 未做（用户一直想做；**说好「功能全做完 + 重构一版 UI」才正式发**）|
| 正式签名 / 正式发版 | ⬜ 现在 release 签 **debug 证书** = 测试版 ⇒ 对用户一律说「**覆盖安装、别卸载**」|
| V2 Windows / V3 macOS+iOS / Linux | ⬜ **都没开始**（§1：一版一版出，别提前动）|
| `需求.md` 标「后续版本」的 | 🚫 **不算欠账**：单卡分享 · 提醒机制 · 记忆生命周期 · 冷启动引导 · 房屋档案 · 多物品拆卡 · 本地 embedding · 安全保险箱 |

⚠️ **回答「开发完成了吗」的正确口径**：**Android 能日常用是真的，但「开发完成」远没到。**
功能面齐 ≠ 验收过 ≠ 后面两版做完。**别把「能装能用」说成「开发完成」。**

**几条 git 现状（2026-09-21 实测，别重复排查）**：

- 远端仓库 `mos1128/findR` **可达**；**tag 本地 17 / 远端 18** —— 多出来的那个
  `flutter-dev-latest` 是 CI 发布的出包标签，**只存在于远端**（`softprops/action-gh-release` 自己建的）。
  RN 侧最新 `apk-m1-fix12`；Flutter 侧出包统一落在 `flutter-dev-latest`（滚动的，每次覆盖）。
- ⚠️ **沙箱里 `.git/refs/remotes/origin/` 建不起来** —— `git fetch origin` 会报
  `new branch main -> origin/main`、`FETCH_HEAD` 也确实写了，可 `refs/remotes/origin/main`
  **就是不落盘**；连 `git update-ref` 都返回 0 却无效，手动 `mkdir` 出的目录会被回滚。
  **不影响 push 与打 tag**（`refs/heads` / `refs/tags` 可正常写入），
  **核对远端直接用 `git ls-remote origin main`**，不需要那个引用。
  真要修就在**用户自己的终端**里跑一次 `git fetch origin`，一条命令的事。
- 桌面 APK（**Flutter 版**；2026-09-22 同一天出了两版，**别装错**）：
  · **`findr-flutter-dev-20260922-b.apk`** ← **要装的是这个**（第十轮，带「全屏相册左右滑」），
    22,204,865 字节，sha256 `e9d0631b725a12af5bfcb5afaebc53539ff98f43f5cdd40f3f93ccd0f7391108`。
  · `findr-flutter-dev-20260922.apk`（第九轮，**已作废**；用户已装过，只差相册滑动）。
  两版都核对过：包名 `com.findr.app.dev` · `android:label="Findr"` · **v2 签名**（debug 证书 ⇒ 可覆盖安装）。
  ⚠️ **RN 那些 `findr-apk-m1-fix*.apk` 已不在桌面上**，别再提「删掉 fix11 免得装错」。
  ⚠️ **一天内重复出包时文件名必须带轮次/序号**，否则「装哪个」这件事迟早出事（本轮已踩）。

---

## 1. 用户拍板的路线（2026-09-21，原话转述）

> 「第一版先出安卓端，然后第二版再出 win 端，然后第三步再出 macOS 和 iOS」

| 版本 | 平台 | 定位 |
|---|---|---|
| **V1** | **Android** | 先跑通整条链路，验证技术选型 |
| **V2** | **Windows** | 桌面第一站 |
| **V3** | **macOS + iOS** | Apple 系一起（都要 Mac 构建，正好一批做）|

**节奏是「一版一版出」，不是一次全上。每版都要能独立跑通、能出包。**

- **Linux**：用户提过要覆盖，但**没排进这三版** —— 放最后，别提前做。
- **鸿蒙**：靠**卓易通**装安卓包，**不为它做任何改动**。
- **UI 重构**：用户此前一直想做。**换成 Flutter 后直接在 Flutter 里做** ⇒
  **没有「把旧界面搬过去」的包袱，直接按新设计写**。
  （这是换栈白拿的好处，别浪费：**不要先照抄 RN 的界面**。）

---

## 2. 为什么换（结论 + 证据，**别再重新调研**）

**一句话**：用户要「六端 + 界面一套代码 + 体积小」，**只有 Flutter 同时给前两项**。

硬证据（完整出处见 `.workbuddy/memory/2026-09-21.md`）：

1. **`package:sqlite3` 3.x 自带预编译 SQLite**（改用 Dart **build hooks** 打包，不再走
   `DynamicLibrary`）—— **默认编译选项含 `SQLITE_ENABLE_FTS5`**，
   覆盖 Android / iOS / macOS / Linux / Windows。
   ⇒ 我们整套搜索可以平移，**而且各平台的 SQLite 编译选项是一致的**（上游明说这是它自带 SQLite 的理由：
   「系统自带的库编译选项不一致、版本常常太旧」）—— 正好对上我们最怕的「各平台能力不一致」。
   ✅ **L1 已实测通过**（SQLite 3.53.4 / `ENABLE_FTS5` / trigram 中文命中），见 §6.1。
2. **Canonical 于 Google I/O 2026 正式接管 Flutter 桌面**（Win/macOS/Linux 的 lead maintainer
   + strategic steward）⇒ **桌面有了专属资源方，是结构性信号**。
3. **Flutter 3.44（2026-06）**：多窗口支持落地、**Windows 走真 Win32**（不是 UWP）、
   跨平台 popup/tooltip/dialog 原语。
   ⚠️ 但本机 `flutter config --list` 里 **`enable-windowing` 报 `(Unavailable)`** ⇒ **V2 做 Windows 时复核**。
4. **Material / Cupertino 正从 core SDK 抽成独立包** ⇒ **框架升级不再强制连带 UI 破坏性变更**
   （对「要重构 UI」的我们意义最大）。
5. `camera_desktop` 已到 **1.2.1**（Linux GStreamer+V4L2 / macOS AVFoundation / Windows Media Foundation，
   枚举·预览·拍照·录像全有）。
6. **体积**：RN 安卓包 **53MB**（已 arm64 单架构）→ Flutter 预计 **20~35MB**（引擎固定成本 4~8MB）。
   **桌面 Flutter 是 30~80MB，比 Tauri 差一档 —— 已知取舍**。

**已评估并排除的方案（别重开这个话题）**：

- **Tauri 2** —— 体积最好（3~10MB）但**三套 WebView 渲染不一致**（WebView2 / WKWebView / WebKitGTK），
  移动端还有三个缺口：相机只有官方插件且仅 iOS/Android、录音只有 0.1 版社区包、
  **安全存储官方无解** ⇒ 只适合当桌面壳
- **KMP + Compose Multiplatform** —— 也能六端，但生态更年轻、团队无底子
- **.NET MAUI** —— 无 Linux 官方支持
- **Electron** —— 无移动端，体积 100~300MB

**换栈解决不了的两件事**（先记住，别期待）：
**iOS 的卡点是 Mac + $99/年**（Apple 的规则，与语言无关）；
**鸿蒙** Flutter-OH 比 RNOH 好，但**也是社区/华为线**，不是 Flutter 官方。

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

**这不是"重新设计"，是"翻译 + 换壳"。** 有 181 个用例当验收网，译错了会立刻被抓住 ⇒
**迁移风险比行数看起来低**。

⚠️ 有个工具迁移后**没用了**：`.workbuddy/tools/probe-hbc-strings.py`（解析 Hermes 字节码字符串表）
是 RN 专有的（Hermes 是 RN 的 JS 引擎）。**Flutter 是 AOT 编译，没有 Hermes，这个工具作废**，
别再找它。但 **APK 拆解手法**（用 Python `zipfile` 按 `compress_size` 聚合）**仍然有用**。

---

## 4. 开工前的 5 个决策 —— ✅ **已于 2026-09-21 全部定案**

**这 5 个已经定了，别再重新讨论。** §4.1 / §4.2 由用户拍板，§4.3 / §4.4 / §4.5 按推荐执行。

### 4.1 ✅ Flutter 工程放哪 —— **同仓 `apps/flutter/`**（用户定）

- 迁移期最大的需求是**随时对照 TS 源码** —— 同仓最方便，改一行 TS 就能旁边看 Dart
- **旧 RN 版还能继续出货**（万一 Flutter 卡住，有退路）
- `.github/workflows/` 里**加一个 flutter job，老的 android job 先留着**（别急着删）

**目录结构（用户 2026-09-21：「按最佳实践来」）**：

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
│     ├─ lib/{db,search,providers,parse,pipeline,backup,prompts,util}/
│     ├─ test/                   ← 181 个用例译到这里
│     └─ pubspec.yaml            ← 依赖只有两条线：`package:sqlite3`（DB）+ `package:http`（联网）
└─ .github/workflows/            ← flutter.yml（新增）+ android.yml（老 job，先留着）
```

**三条关键设计点（别改）：**

1. **Dart core 做成独立 package，不要塞进 app 的 `lib/` 下** —— 它是纯 Dart，
   可以用 `dart test` 直接跑，不必起 Flutter 环境、不被 widget 测试拖慢；
   **V2/V3 桌面版复用同一个 core**，不用复制；也与现有 `apps/` + `packages/` 结构对称。
2. **数据库依赖只有一层**：`findr_core` 依赖 **`package:sqlite3` 3.x**，就这一条。
   它**自带预编译 SQLite** ⇒ **app 端不用再补任何 native 库依赖**，
   **连本机的 `sqlite3.dll` 都不用准备**。（此前「core 用 sqlite3 + app 加 `sqlite3_flutter_libs`」
   的设计**已作废**，见 §4.5。）
   （后来又加了 `package:http` + `http_parser` —— 那是**联网**那条线，与 DB 无关；
   它同样是 Dart 官方包、纯 Dart、无 native 依赖，不破坏「app 端不用补 native 库」这条。）
3. **名字用 `findr_core` 而不是 `core_dart`** —— Dart 包名必须 snake_case，
   且这样能与 `packages/core`（TS 老版）一眼区分。

**另外两条工程约定**：
`.gitignore` 用 Flutter 工程自带的（**别把 `build/`、`.dart_tool/` 提交进来**）；
**CI 里的 Flutter 版本号写死成与本地相同的具体版本**（不要写 `channel: stable`，见 §7.1.1）。

### 4.2 ✅ 旧 RN 项目怎么处理 —— **保留，不删**（用户定）

- 它是迁移期的**参照实现**，也是**回滚路**。用户原话：「旧版保留方便对照」
- 等 **V1（安卓）在真机上跑通并验收过**，再考虑归档

### 4.3 ✅ core 怎么处理 —— **必须用 Dart 重写**（唯一没有捷径的一件）

**没有成熟方案让 Dart 调用 TS core**（Dart 调 JS 要么嵌引擎、要么 core 编 WASM，都不成熟且更重）。
但**按块译、每块用对应测试验收**，别一口气译完。顺序是**从底层往上，依赖少的先做**
（实际执行顺序见 §6.2）。

⚠️ **`zod` 在 Dart 没有等价物**：手写校验函数即可，**不要为了"对齐 zod"引入一个重 ORM/校验框架**。

### 4.4 ✅ 状态管理选型 —— **Riverpod**

- 当前 Flutter 主流，编译期安全、好测、不依赖 `BuildContext`
- 备选：Bloc（更结构化、更重）、Provider（更旧）

### 4.5 ✅ 数据库方案（2026-09-21 两次修订，**当前口径以下面为准**）

**只依赖 `package:sqlite3` 3.x（已实测：3.6.0），直接写 SQL。**

- 它用 **Dart build hooks** 把 **预编译 SQLite** 打包进应用 ——
  **默认编译选项含 `SQLITE_ENABLE_FTS5`**（还会带上 `SQLITE_ENABLE_DBSTAT_VTAB`、
  `SQLITE_ENABLE_RTREE`、`SQLITE_ENABLE_MATH_FUNCTIONS` 等）
- 预编译覆盖 **Android（armv7a / aarch64 / x86 / x64）**、iOS、macOS、Linux、Windows、Web
  ⇒ 我们 arm64 单架构的 APK 在覆盖范围内
- **它默认优先用自带的这份，而不是系统的那份** ⇒ 各平台行为一致

⚠️ **两条过时信息，别再照做：**

1. **`sqlite3_flutter_libs` 已废弃**（版本号 `0.6.0+eol`，README 明说「什么都不做」；
   `package:sqlite3` 3.x 的升级说明要求把它删掉）—— **app 端什么都不用加**。
   网上大量教程还写着它，属于过时信息。
2. 本地验证**不再需要手工准备 `sqlite3.dll`** —— `dart test` 会自己拉预编译库。

**`drift` 仍不引**（理由不变）：

1. 我们有一整套**现成的 SQL 要逐字搬**（见 §3）—— drift 的 DSL / codegen 反而多一层翻译，
   正好把我们最省事的那条路堵上
2. 迁移逻辑我们本来就是手写的（`user_version` 分步推进），drift 的 `MigrationStrategy` 省不了多少
3. 少一层 codegen ⇒ 少一个 CI 步骤、少一类「生成物没同步」的故障

**留后门**：drift 底层就是 `sqlite3`，若将来迁移或查询复杂度涨上来，随时能在其上加一层，
不影响已译好的代码结构。

⚠️ **唯一还没验的是「打包进 APK 之后」那一层**（见 §6.1 的第 2 层）——
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

## 6. 进度与下一步

### 6.1 命门（FTS5 + trigram）—— **三层全部 ✅（2026-09-22 收口）**

> 建一张 FTS5 表 + **trigram 分词器**，插入中文内容，用 **3 个字以上**的词做 `MATCH`，**必须命中**。
> 我们整套检索完全建立在这上面。**这一条不通 ⇒ 整个方案要重新评估。**

自检逻辑收在 **`packages/findr_core/lib/selfcheck.dart`**（`runCoreSelfCheck()`，共 **7 项**），
**三层共用同一份**，不会出现「自检屏写漏一项」这种不对称。

**第 1 层 · 本地纯 Dart —— ✅ 已通过（2026-09-21）**

押注落在 **`packages/findr_core/test/selfcheck_test.dart`**（跑 `dart test` 约 1 秒复现）：

| 项 | 实测值 |
|---|---|
| SQLite 版本 / FTS 编译选项 | **3.53.4** / **`[ENABLE_FTS5]`** |
| 3 字中文 `MATCH '圆珠笔'`（库里是「蓝色的圆珠笔放在书桌抽屉里」）| **命中 1 条** |
| 2 字 `MATCH '圆珠'` / 1 字 `MATCH '笔'` | 0 条，**不抛异常** |

**顺带确认了一件重要的事**：短查询是**返回空**而不是**报错** ⇒
TS 侧「≥3 字走 `MATCH`、更短的走 `LIKE` 降级」这条设计**照搬即可**，不需要额外加 try/catch 兜底。

**中间层 · Flutter 工具链 —— ✅ 已通过（2026-09-22，本轮新增）**

`apps/flutter/test/self_check_smoke_test.dart`（`flutter test`）。它比第 1 层多验了**一件关键的事**：
`package:sqlite3` 的 **Dart build hooks 真的在 Flutter 工具链下跑起来了**，产物是它自己那份
预编译 SQLite，而不是退化去开系统库。实测证据（同一份自检，值也与第 1 层一致 ⇒ 同源）：

```
✅ SQLite 版本 — 3.53.4
✅ FTS5 编译选项 — ENABLE_FTS5
✅ trigram 分词器 — CREATE VIRTUAL TABLE ... tokenize=trigram 成功
✅ 3 字中文 MATCH「圆珠笔」 — 命中 1 条（期望 1）
✅ 短查询（2 字/1 字）返回空且不抛异常 — 「圆珠」⇒ 0 条；「笔」⇒ 0 条
✅ 迁移 + 种子数据 — categories=3、schema_version=2
✅ cards_fts 由迁移建出 — 现有 0 行
```

旁证（可复现）：`.dart_tool/hooks_runner/sqlite3/` 有 hook 的 `input.json`/`output.json`，
`build/native_assets/windows/native_assets.json` 明确记着
`package:sqlite3/src/ffi/libsqlite3.g.dart → …\native_assets\windows\sqlite3.dll`。
⇒ **不需要 `flutter config --enable-native-assets`，3.47.5 下默认就是开的**（原本担心这点，现在不用管了）。

**第 2 层 · 真机 —— ✅ 已通过（2026-09-22，用户实测）**

用户在真机上装好 `flutter-dev-latest` 后，进 **设置 → 维护 → 自检**，
**两组全部全绿**。⇒ **随 APK 发到手机上的那份 SQLite 确实带 FTS5 + trigram，整套检索方案成立。**

同一轮真机反馈还确认了**媒体链路**也是好的（竖着拿手机拍的照片存下来是正的 ——
即 `image` 包那个「EXIF 转两遍」的坑确实绕过去了，见 §6.3）。

**出包链路与产物级断言（前置筛子）也都跑通了**：

| 需要的东西 | 状态 |
|---|---|
| 真机上跑的自检屏 | ✅ `apps/flutter/lib/selfcheck/self_check_screen.dart`。**入口在「设置 → 维护」**（`main.dart` 的 `home` 早已换成记忆流主页，不再是自检屏）|
| 能装到真机的 APK | ✅ CI 的 `apk` 作业已多次实测出包（第九轮 **22.1MB**）。本机没装 Android SDK，出包只能走 CI |
| 产物级断言 | ✅ 该作业会从 APK 里抽出 SQLite 的 `.so`，断言二进制里**含 `fts5` 与 `trigram`**（模块按名注册，名字串会留在二进制里）。第九轮实测：`fts5` 出现 **38** 次、`trigram` **1** 次 |

⚠️ **三层各验的是不同的一份东西，别互相冒充**（铁律 5 的同类问题）：
第 1 层验桌面上的 libsqlite3、中间层验 Flutter 工具链编出来的 native assets、
第 2 层验的才是**真正随 APK 发到手机上的那份二进制**。
（第九轮出包前的产物级断言虽然能挡掉「native assets 没打进包」，
但它只证明「**编进去了**」，证明不了「**运行时跑得起来**」—— 后者才是第 2 层。）

### 6.2 翻译进度（core 5,429 行口径）

| 顺序 | 模块 | 状态 |
|---|---|---|
| 1 | 骨架 | ✅ `apps/flutter/`（Flutter 3.47.5，`--platforms=android`，`com.findr.app.dev`）+ `packages/findr_core/`（纯 Dart，依赖 `sqlite3`）|
| 2 | `db/` 那一层 | ✅ **全部译完**（2026-09-21 分两轮，明细见下）|
| 3 | `search/` | ✅ **全部译完**（2026-09-22，含 `builder`）；顺带把它依赖的 `parse/` `prompts/` `providers/types` 一并译掉 |
| 4 | `providers/` 联网层 + `settings` + `util/` | ✅ **全部译完**（2026-09-22，明细见下）|
| 5 | `pipeline/` 录入编排 + `cards/` + `media/` | ✅ **全部译完**（2026-09-22，明细见下）|
| 6 | `backup/` `.findrpack` 导出导入 | ✅ **全部译完**（2026-09-22，明细见下）—— **core 到此实质译完** |
| 7 | UI | ✅ **已写完**（2026-09-22，**按新设计写、没照抄 RN**）：`theme/` `ui/` `state/` `capture/`（含媒体录入）`screens/` —— 见 §6.3 |

**第 2 项明细（✅ 2026-09-21，合计 1,476 行 TS）**：

| TS 源 | 行 | Dart |
|---|---|---|
| `driver.ts`（接口）| 12 | `db/driver.dart` + `db/driver_sqlite3.dart`（`package:sqlite3` 实现）|
| `json.ts` | 14 | `db/json.dart` |
| `schema.ts` | 240 | `db/schema.dart`（DDL **逐字搬**，v1/v2/seed 三个数组）|
| `migrate.ts` | 78 | `db/migrate.dart` |
| `settings.ts` | 43 | `db/settings.dart` |
| `types.ts` | 81 | `types.dart`（枚举用 enum + `wire`，落库/进包走 `wire`）|
| `repository.ts` | 648 | `db/repository.dart`（**core 里最大的单文件**）|
| `taxonomy.ts` | 174 | `db/taxonomy.dart` |
| `search/builder.ts` | 186 | `search/builder.dart`（repository 靠它的 `escapeLike`，顺带译掉）|
| ——（**新增**）| —— | `util/iso.dart`（见下）|

**第 3 项明细（✅ 2026-09-22，本轮合计 1,160 行 TS）**：

| TS 源 | 行 | Dart |
|---|---|---|
| `prompts/templates.ts` | 221 | `prompts/templates.dart`（**18 个模板逐字搬**，`r'''...'''` 原样字符串，改一个字就是错）|
| `prompts/render.ts` | 138 | `prompts/render.dart`（`{{占位}}` 替换 + P1/P2/P3/P4 组装 + 分类/位置/字段说明格式化）|
| `parse/index.ts` | 116 | `parse/outputs.dart`（P1/P2/P3/P4 形状）+ `parse/schema.dart`（**手写校验取代 zod**）+ `parse/model_json.dart`（`extractJson`/`fixJson`）|
| `providers/types.ts` | 84 | `providers/types.dart`（适配器接口 + `Part`/`AudioRef`/`ChatRequest` 等契约）|
| `providers/fake.ts` | 22 | `providers/fake.dart`（测试替身，队列式应答 + 记录请求）|
| `search/inventory.ts` | 190 | `search/inventory.dart`（**相关性打分**：字段权重 entity 6 / tags 4 / category 3 / path 2 / body 1；≥4 字词 ×2 加权；**先排序再截断**）|
| `search/service.ts` | 193 | `search/service.dart`（**检索主流程**：P2 规划 → 本地字面检索（含放宽阶梯）→ advise → 字面兜底）|
| `search/advise.ts` | 104 | `search/advise.dart`（清单 → P4 模型裁决，取 refs：去重 + 丢假 id）|
| `search/answer.ts` | 92 | `search/answer.dart`（摘要 → 答案，去重截断）|

**第 4 项明细（✅ 2026-09-22，本轮合计 1,034 行 TS）**：

| TS 源 | 行 | Dart |
|---|---|---|
| `providers/openai-compat.ts` | 195 | `providers/openai_compat.dart`（**两套协议的线格式之一**：`/v1/chat/completions` + `/v1/audio/transcriptions`）|
| `providers/capabilities.ts` | 211 | `providers/capabilities.dart`（**四态探测** ok / unsupported / unknown / error）|
| `providers/samples.ts` | 141 | `providers/samples.dart`（运行时造 64×64 PNG 与 1 秒 WAV：存储型 deflate 块 + CRC32/adler32）|
| `settings.ts` | 138 | `settings.dart`（**设置项唯一权威**：JSON 形状与 TS 逐字段对齐，含浅合并语义）|
| `providers/anthropic.ts` | 122 | `providers/anthropic.dart`（`/v1/messages`；**401/403 才换 `x-api-key` 重试一次**）|
| `util/utf8.ts` | 64 | `util/utf8.dart`（纯算法逐字搬，见下）|
| `providers/factory.ts` | 50 | `providers/factory.dart`（设置 + Key → 适配器）|
| `util/base64.ts` | 50 | `util/base64.dart`（纯算法逐字搬，见下）|
| `providers/sse.ts` | 49 | `providers/sse.dart`（流式读取骨架 + 两套 delta 提取）|
| `providers/media.ts` | 14 | `providers/media.dart`（文件端口；`audioPart` 返回具体 `MultipartFile`，见下）|
| ——（**新增**）| —— | `providers/transport.dart`（URL 归一化 / 超时 / 读体，把 TS 里写了两三遍的重复收拢）|

**第 5 项明细（✅ 2026-09-22，本轮合计 728 行 TS）**：

| TS 源 | 行 | Dart |
|---|---|---|
| `pipeline/capture.ts` | 326 | `pipeline/capture.dart`（**core 里最绕的一件**：`AdvanceDeps` + 草稿 → 转写 → 理解 → 入库；`UnderstandingResult` / `AdvanceOutcome` 用 sealed class + enum）|
| `pipeline/edit.ts` | 156 | `pipeline/edit.dart`（补文字 / 重新整理 / 补分析 / 重生成 desc，四个入口都建在 `runUnderstanding` 上）|
| `pipeline/queue.ts` | 119 | `pipeline/queue.dart`（串行重试队列；模块级 `_running` 锁 + `resetQueueLockForTest`）|
| `cards/badges.ts` | 77 | `cards/badges.dart`（角标判定 + 文案 + `canReanalyze`；`CardBadge` 枚举带 `wire`）|
| `media/paths.ts` | 35 | `media/paths.dart`（媒体相对路径规则；**月份用本地时间**，与 `isoUtc` 那套时间戳不同源，见下）|
| `pipeline/ingest.ts` | 15 | `pipeline/ingest.dart`（`ingestText` 薄封装）|

验收网：`pipeline.test.ts` **31 个用例**（逐字译成 `test/pipeline/pipeline_test.dart`）+
`badges.test.ts` 9 个（`test/cards/badges_test.dart`）+
`samples.test.ts` 6 个（`test/pipeline/samples_test.dart`，**20 条手工样本集已搬成
`test/fixtures/samples.dart`**）。合计 **46 个新用例**。

**第 5 项的两处有意偏离**：

1. ⚠️ **`queue.ts` 的 `QueueDeps extends AdvanceDeps` 译不过来**：Dart 没有结构化子类型，
   硬造包装类会让每个调用点多一层解包。改成 `runQueue(AdvanceDeps deps, {bool? vision, int? max})`
   —— 那个多出来的 `vision` 字段提成具名参数，语义相同；
   `retryAllTranscriptions` 里 TS 的 `{...deps, hotwords}` 由 `AdvanceDeps.withHotwords(...)` 承担
   （与 `P2Output.withSynonyms` 同一套路）。`__resetQueueLock` → `resetQueueLockForTest`。
2. 📌 **`media/paths.dart` 的月份目录用本地时间，不是 `isoUtc()`** —— 与第 1 条口径**不冲突**：
   那条管的是**写进数据库的列值/排序键/备份字段**；媒体目录名是**给人看的文件夹**，
   TS 侧用的就是本地 `getMonth()`，改成 UTC 会让「1 月拍的照落到 12 月文件夹」。
   代码里写了注释，别顺手「统一」掉。
3. 📌 TS 的 `audioPart` 返回 `Blob`/`{uri,name,type}`，Dart 返回具体 `http.MultipartFile` ⇒
   断言 `{kind:'file', rel, mime}` 改成 `isA<AudioFileRef>()` + 字段判等。

**第 6 项明细（✅ 2026-09-22，本轮合计 996 行 TS）**：

| TS 源 | 行 | Dart |
|---|---|---|
| `backup/manifest.ts` | 398 | `backup/manifest.dart`（manifest 生成 + **导入合并策略**；`publicSettings` 走白名单 + 按键名深层剥除）|
| `backup/zip.ts` | 232 | `backup/zip.dart`（**只支持 STORE 的最小 ZIP 读写**；每个成员都验 CRC32）|
| `backup/pack.ts` | 167 | `backup/pack.dart`（导出/导入入口；**先写媒体再合并 DB** —— 反过来会留下指向空文件的卡片）|
| `backup/types.ts` | 120 | `backup/types.dart`（端口 + 报告类型 + **卡片/分类/位置/别名的 JSON 胶水**）|
| `backup/format.ts` | 58 | `backup/format.dart`（7 字节容器头；**别在加加密之前动它**）|
| `backup/crc32.ts` | 16 | `backup/crc32.dart`（查表法，逐位与 TS 同值）|
| `backup/index.ts` | 5 | ——（Dart 用 `findr_core.dart` 统一导出）|

验收网：`backup.test.ts` **17 个用例**全部逐条译成 `test/backup/backup_test.dart`，
另加 `test/helpers/memory_media.dart`（对应 TS `test/memory-media.ts`）与
`tool/export_probe.dart`（手工冒烟：写一份真实 `.findrpack` 到磁盘，供外部工具验）。

**第 6 项的四条要点（比别处更值得记）**：

1. ⚠️ **`MediaStorePort` 的「可选方法」在 Dart 里得换个写法**：TS 的 `exists?` 是可选成员，
   Dart 接口不支持 ⇒ 改成**可空的函数类型 getter**（`FutureOr<bool> Function(String)? get exists`），
   为 null 即「未实现」。调用点的判断方式与 TS 一模一样。
   顺带：`MaybePromise<T>` ⇒ 直接用 SDK 的 `FutureOr<T>`。
2. ⚠️ **`Uint8List` 上没有 `byteOffset` / `byteLength`**（那是 JS 的名字）——
   Dart 的 `TypedData` 叫 **`offsetInBytes` / `lengthInBytes`**。构造 `ByteData.view` 时写错就是编译错。
3. ⚠️ **Dart 的 `DateTime` 带 `isUtc` 标记，JS 的 `Date` 没有** ⇒
   凡 TS 用 `getFullYear()` / `getHours()` 这类**本地时间取值器**的地方（`media/paths.ts` 的
   `monthDir`、`backup/zip.ts` 的 DOS 时间戳），Dart 必须先 `.toLocal()`，
   否则传进来一个 UTC 时刻会拿到 UTC 的年月/时分 —— **跨月那几小时会让文件落错文件夹**。
   （这与「写库时间一律 `isoUtc()`」不冲突：那条管的是数据库列值，这条管的是本地语义的取值器。）
4. 📌 **`BackupManifest.media` 用 `List?` 而不是 `List`**：TS 的 `manifest.media?.length ?? mediaEntries.length`
   区分了「键不存在」与「空数组」，塌成 `[]` 就丢掉这个区别。同理 `toJson` 里
   **`appVersion` 为 null 时要显式省略键**（TS 的 `JSON.stringify` 会省略 `undefined`，
   而 Dart 的 `jsonEncode` 会写出 `"appVersion": null`）。
5. 📌 **`validateManifest` 顺手做了 `fromJson`**：TS 只是「判完把原对象当 `BackupManifest` 用」
   （JS 的鸭子类型），Dart 没有这种便利 ⇒ 必须真转一次。**校验规则与报错文案仍逐条对齐 TS**。

**这一次第一次做了「跨实现互认」实测**（铁律 5：得在真实的那一层上看，自证不算）：

| 验证 | 手段 | 结果 |
|---|---|---|
| Dart 产出的包是不是真 ZIP | Python `zipfile` 打开 | ✅ `namelist` 正确、`testzip()` → `None`（**所有成员 CRC 均通过**）|
| 容器头 | 直接读字节 | ✅ `FINDR` + 小端 u16 = 1，头长 7 |
| 白名单剥除 | Python 读 manifest | ✅ `settings.llm` 里**只有 providerType/baseUrl/model**，canary `apiKey` 不在；整包字节里也搜不到 |
| **RN(TS) 能不能导入 Flutter(Dart) 的包** | 临时 vitest 用例跑 TS 的 `importBackup` | ✅ 2 张卡入库、位置两级、媒体 2 个、`pathNames` 与 desc 一致、无 canary |

⇒ **RN 版与 Flutter 版的备份包双向互认已实测通过**，用户的旧备份可以带过来。

**验收网**：`dart test` **289 通过**（272 + 本轮 17）、`dart analyze` 无问题；
`flutter test` **2 通过**（2026-09-22 补，含命门中间层）、`flutter analyze` 无问题；
**RN 侧 `pnpm check` 仍 181 passed | 2 skipped**（基线未破）。
**全局进度约 5,394 / 13,894 行 ≈ 39%**（按「需要动脑的行数」算比这个高 ——
`templates.ts` 与全部 SQL 是逐字搬）。**core 实质译完（只剩一个 35 行的 TS 桶文件）。**

**翻译时的三条口径（都是踩过才有的）**：

1. ⚠️ **凡是要写进库的时间，一律走 `util/iso.dart` 的 `isoUtc()`**。这文件 TS 侧没有，但**不是自由发挥**：
   JS 的 `Date.toISOString()` 恒产出 UTC 的 `...Z`，而 Dart 的 `DateTime.toIso8601String()`
   对本地时间会输出 `+08:00` 偏移形式。这些字符串同时是**列值、排序键、备份包字段**，
   形状一变就全错，还会与真机库里已有数据混在一起再也分不开。
2. ⚠️ **zod 在 Dart 无等价物（§4.3）⇒ 手写校验落在 `parse/schema.dart`**。关键**不是「能校验」，
   而是逐字复刻 zod 的 `.catch()` 边界**：
   `.catch()` 挂在**字段**上是「这一档坏了，只有这一档回退」；挂在**数组**上则是
   「数组里混进一个坏的 ⇒ **整个数组落空**」。复刻错了**不会报错**，只会**静默地少答一条**。
   `parse_test.dart` 就是专门钉这个边界的（对照 TS `parse.test.ts` 7 个用例）。
   返回类型用 sealed 的 `ParseResult<T>`（`ParseOk` / `ParseFailure`），消费方走 `switch` 穷尽。
3. ⚠️ **Dart 没有变长参数** ⇒ 驱动接口刻意保持 TS 的 `exec` / `prepare` / `transaction` 形状，
   但参数要包成一个**列表**。`repository.ts` 有大量 `db.prepare(sql).get(x)`，形状对上才抄得动。
   **事务必须支持嵌套**（内层走 SAVEPOINT）—— `taxonomy` / `repository` 里存在事务套事务的调用，
   手写 `BEGIN` 遇嵌套会直接抛「cannot start a transaction within a transaction」。
4. 📌 另一处**有意偏离**（代码里都写了原因）：`currentSchemaVersion` 读出坏值时当 0
   （TS 是 NaN，等于**什么都不迁、只把版本号覆写掉**）；当 0 是宁可重跑一遍，
   安全性由「v1 全 `IF NOT EXISTS` + v2 可重复执行」保证，已用幂等用例钉住。
5. ⚠️ **`util/base64.dart` 与 `util/utf8.dart` 是逐字搬的，不是「顺手换成 `dart:convert`」**。
   它们存在的理由（RN 没有 Buffer、Hermes 不稳）在 Dart 不成立，但**语义有两处真的不同、
   而且我们依赖**：① base64 **解码对非法字符宽容**（跳过后返回已解出的部分），
   `base64Decode` 直接抛 `FormatException`；② UTF-8 **解码遇截断序列按 0 补齐**
   （JS 的 `undefined & 0x3f === 0`），Dart 不特判就抛 `RangeError`。
   备份包解析路上「崩掉」比「解出几个错字」更难收拾。两条差异**都有对照组断言**钉着
   （`test/util/` 里边断言我们宽容、边断言 `dart:convert` 是抛）。
6. ⚠️ **超时：`Future.timeout` ≠ `AbortController`**。TS 的 `abort()` 真掐 socket；
   Dart 的 `Future.timeout` 只是「不再等」。所以流式那条路**另外**套了一层 `Stream.timeout`
   —— 它到点会**真正 cancel 订阅**，连接随之释放。差异与理由都在 `providers/transport.dart`。
7. 📌 **三处新的有意偏离**（都在代码注释里写了）：
   - `providers/media.dart` 的 `audioPart` 返回**具体的 `http.MultipartFile`** 而不是 TS 的 `unknown`
     （Dart 只有一个运行时，那个「谁实现谁转型」的洞没必要留；实现方可直接 `fromPath` 走流）。
   - `providers/transport.dart` 是**新增文件**：TS 把 URL 归一化写了两遍、
     超时写了两遍半、`res.text().catch(()=>'')` 写了四遍，收拢成一个内部小件。
     **刻意不从 barrel 导出** —— 它是实现细节，不是对外契约。
   - `makeLlmAdapter` 遇到 `gemini`/`fake` 显式抛 `UnsupportedError`：
     TS 那边是 `switch` 漏空返回 `undefined`，然后在调用点崩成「undefined 不是函数」。

**下一块（UI）的要点**：core 已译完，**只剩 UI 没动**。UI 在 `apps/flutter/`，
**按新设计写，别照抄 RN 界面**（用户还没动手重构 UI —— 这是换栈白拿的好处，见 §1）。

动手之前的两件前置，**都已在 2026-09-22 办完**：

1. ✅ **CI 的 flutter job 已加**：`.github/workflows/flutter.yml`，两个作业 ——
   - `checks`（push main / PR / 手动）：core 的 `dart analyze` + `dart test`，app 的
     `flutter analyze` + `flutter test`。是迁移期的验收网。
   - `apk`（**只有 tag `fapk-*` 或手动才跑**）：出 arm64 release APK，跑上面那套测试，
     **再从 APK 里抽出 SQLite 的 `.so`，断言二进制里含 `fts5` / `trigram` 字符串**，
     最后发到 `flutter-dev-latest`（**刻意与 RN 的 `dev-latest` 分开**，两个包能并排装）。
   版本号**写死 `flutter-version: '3.47.5'`，绝不写 `channel: stable`**（本机 `scoop hold` 那层
   只保住了开发机）。tag 前缀用 `fapk-*` 而不是 `apk-*`：**免得一个 tag 同时引爆 RN 与 Flutter 两条流水线**。
2. ✅ **命门第 2 层已于 2026-09-22 通过**：用户装上 APK → 设置 → 维护 → 自检，
   **两组全绿** ⇒ 随包发出去的那份 SQLite 确实带 FTS5 + trigram，三层全部收口（见 §6.1）。
   （另同日确认：竖拍照片存下来是正的 —— 媒体链路的 EXIF 方向也过了真机。）
   ⚠️ **自检入口随界面落地挪了位置**：`main.dart` 的 `home` 现在是**记忆流主页**，
   自检屏改从**设置 → 维护**进（原先是启动即自检屏）。**别照着旧口径去启动页找。**

⚠️ **本机没装 Android SDK，出包只能走 CI** —— 这才是「必须先补 CI、再验第 2 层」的真实原因。

UI 侧待办的口径（都写在 §5 与需求里，别漏）：

- ⚠️ **明文备份必须在界面上说清楚**：页面红条 + 导出前确认框 —— 当前版本不加密，
  谁拿到 `.findrpack` 都能读出全部记忆。
- ⚠️ **发布仍是测试版**（release 签 debug 证书、可覆盖安装、数据保留）；
  **功能全做完 + 重构一版 UI** 之后才正式发，**换签名放那一步**。
  ⇒ 对用户一律说「**覆盖安装、别卸载**」。
- ✅ **`ask`（补问）/ `path_suggestion`（位置猜测）已在界面上展示**（`ui/card_row.dart` + `screens/card_detail_screen.dart`）——
  需求 5.1 只要求「在卡片列表与详情页显示『想确认：…』」，**这条已满足，不算欠账**。
  ⚠️ 唯一还差的是**「一键采纳猜的位置」**：现在只印一行「模型猜的位置：…」，
  要采纳得自己去位置选择器重选一遍。`path` 的语义是「内容提到存放位置才有值」，
  **猜错比空着更糟** ⇒ 即使做，也必须是**用户点一下才应用**，绝不能默认自动填。
- ⚠️ 出网口径不变：**只往用户自填的 `baseUrl` 发请求**，别引入任何我们自己的后端。

**验收方式**：UI 没有 TS 侧的对照测试网，只能靠**真机手动过一遍**（`测试计划.md` 的场景清单
+ `test/fixtures/samples.dart` 那 20 条样本可以当录入素材）。**别靠"看起来对了"。**

✅ **那笔债已还**：`P2Output` 等的手写校验已随 `parse/schema.dart` 落地（上面第 2 条）。
（`migrate_test` 里造旧库用的两处原始 SQL **不是债**：一处在填「要删的列」、一处要带
`needs_confirm = 1` —— 那些列已从仓储的列清单里摘掉，手写 SQL 正是被测的事实本身。
其余造数据与断言都已走仓储，与 TS 同源。）

### 6.3 应用层（`apps/flutter/`）进度

RN 那边应用层是 `apps/mobile/src/`：`platform/`（接线）+ `app/`（路由与页面）+ `ui/` + `capture/`。
Flutter 这边**从 `platform/` 开始接**，因为那部分是**与界面设计无关**的 —— 任何界面都得有它。

| RN 源 | Dart | 状态 |
|---|---|---|
| `platform/db.ts`（op-sqlite 适配）| `packages/findr_core/lib/db/driver_sqlite3.dart` | ✅ 适配与 PRAGMA 已在 core 里，app 侧只剩路径 |
| —— | `platform/app_paths.dart`（**新增**）| ✅ 沙盒绝对路径唯一来源；`main()` await 一次后全程同步（`MediaIo.fileUri` 是同步的）|
| —— | `platform/db.dart`（**新增**）| ✅ 库名与 RN 同名 `findr.sqlite`；`openFindrDb()` / `openAndMigrateDb()` |
| `platform/media.ts` | `platform/media.dart` | ✅ `MediaIo` + `MediaStorePort` 两个端口的设备实现 |
| `platform/selfcheck.ts` | `platform/device_selfcheck.dart` | ✅ 设备层 5 项（**不重复** core 已验的 FTS5/trigram/迁移）|
| `platform/secure.ts` | `platform/secure.dart` | ✅ `flutter_secure_storage`。槽位 **`findr.llm.apiKey` / `findr.asr.apiKey` 与 RN 逐字相同**（升级用户不必重填）。读不到 Key 吞成 `null` = 「没配」，不是错误 |
| `platform/backup.ts` | `platform/backup.dart` | ✅ `share_plus` + `file_picker`。挑文件**用 `FileType.any`**（限定 `.findrpack` 会让 Android 选择器把它置灰）；把关交给 core 的 magic 校验 |
| `platform/runtime.tsx` | `platform/runtime.dart` | ✅ Riverpod。`RuntimeState` 快照 + `dbProvider`（**全生命周期只开一次库**）+ `runtimeProvider.refresh()`（保存设置后重读）。**不做业务判断** |
| `ui/`（RN 设计系统）| `theme/tokens.dart`（**新增**）| ✅ **全新设计令牌**：`FindrColors extends ThemeExtension`（light/dark 两套、`lerp` 可插值）+ `Spacing` / `Radii` / `maxContentWidth` + `buildFindrTheme(Brightness)`。**类名是 `Radii` 不是 `Radius`**（后者与 `dart:ui` 的 `Radius` 撞名）|
| `ui/*`（RN 组件）| `ui/kit.dart`（**新增**）| ✅ 组件箱：`ScreenBody`（CustomScrollView + 居中 + 限宽 800）/ `Panel` / `FindrButton`（4 变体）/ `FindrChip` / `FindrBadge` / `Notice`（**恒在文档流里，绝不浮层**）/ `EmptyState` / `FindrField` / `ListRow` / `FindrTopBar` |
| —— | `ui/media_view.dart`（**新增**）| ✅ `mediaFileOf` / `MediaThumb` / `MediaFull` / **`openImageViewer`（全屏相册，同卡片多张可左右滑）**。**`AppPaths.ready == false` 时返回 null 而不是抛**（缩略图退化成带来源图标的占位块，不留白框）|
| `ui/` 卡片行 | `ui/card_row.dart`（**新增**）| ✅ 角标**只画不算** —— 判定全部走 core 的 `cardBadges` / `badgeLabel` / `BadgeContext`（单一真相源）|
| `state/`（RN Zustand）| `state/memory_stream.dart`（**新增**）| ✅ **Riverpod AsyncNotifier**：记忆流 + 检索视图（流/结果/答案三态）+ 分类筛选 + `drainQueue`。`search()` 特意不叫 `runSearch`（避开与 runtime 同名）|
| `capture/`（RN 文件录入）| `capture/text_file.dart`（**新增**）| ✅ 文本文件摄取。**超限不静默截断**（8,000 字上限，超了连实际字数一起退回）；BOM 剥掉；扩展名白名单 |
| `capture/`（RN 录入坞）| `capture/composer.dart`（**新增**）| ✅ 底部录入坞：文字 + 文本文件 + **拍照 / 连拍 / 相册 / 长按录音**（媒体那几块的实现见下面第九轮那张表）|
| `app/index.tsx`（记忆流主页）| `screens/memory_stream_screen.dart`（**新增**）| ✅ 新首页：搜索框 + 分类 Chip 条 + 结果头 + **AI 答案卡（挂在列表下方，不盖列表）**；回前台自动 `drainQueue` |
| `app/card/[id].tsx`| `screens/card_detail_screen.dart`（**新增**）| ✅ 实体字段编辑、位置选择、重排/重析/重生成/推进、删除。**音频回放走 `ui/audio_player.dart`**（RN 那边只是把路径印出来）|
| `app/settings/*`（5 屏）| `screens/settings/*`（**5 个新文件**）| ✅ `provider`（双槽位 llm/asr + 探测，**区分「不支持」与「没测出来」**）· `settings`（7 面板）· `categories`（增删改排序）· `locations`（**改名必调 `refreshPathNames`**）· `backup`（**红条「当前版本不加密」+ 导出确认框两道闸**）|
| `main.tsx` | `main.dart`（**重写**）| ✅ `await AppPaths.init()` 后 `runApp(ProviderScope(...))`；`home` 从自检屏**换成记忆流主页**；`themeMode: system` |
| —— | `test/text_file_test.dart` · `test/memory_stream_test.dart`（**新增 29 用例**）| ✅ 文本摄取边界 21 条 + 界面行为 8 条（空态/打字落库/空白不落库/字面兜底/搜不到/回流体/分类筛选/可滚动）|

**界面已按新设计写完（14 个新文件 + `main.dart` 重写）**，`flutter test` 从 8 涨到 **37**。
**没照抄 RN 的界面**（§1 那条「换栈白拿的好处」兑现了）。

**本轮两个被测试抓出来的真 bug（都属「看着正常但其实坏的」）**：
1. **录入坞「存」按钮永远点不亮** —— 原先 `if (has != _canSubmit) setState(...)` 里
   `_canSubmit` 每次重读 `_controller.text`，值恒等 ⇒ `setState` 从不触发，按钮一直是禁用态。
   改用 `_hadText` 字段记录上一次的值才修好。**这类「读同一个源的 getter 拿去和自己比」是个通用陷阱。**
2. **`runtimeProvider` 在测试里卡在 `AsyncLoading`** —— `build()` 里 `await appVersion()`
   （`package_info_plus`）在测试宿主里**永远不返回**，整个界面停在转圈。
   改成 `build()` 直接返回 `openRuntime(...)`、用 `unawaited(_fillVersion(rt))` 后补版本号。
   ⇒ 通用口径：**`package_info_plus` 这类平台插件别放在首帧的关键路径上 `await`。**
   （顺带把 `appVersion()` 的 `.timeout()` 也去了 —— 挂着的 timer 会让 widget test 报未完成计时器。）

**媒体录入与回放（第九轮补完，`flutter test` 37 → 72）**

| RN 源 | Dart | 说明 |
|---|---|---|
| `capture/compress.ts` | `capture/image_compress.dart` | ✅ 纯函数、可测。`image` 包压到 WebP。**两个坑见下** |
| `capture/picker.ts` + `CameraModal.tsx` | `capture/photo_picker.dart` | ✅ **刻意改用系统相机**（`image_picker`）替代应用内取景器 —— 理由见下 |
| `capture/recorder.ts` | `capture/recorder.dart` | ✅ `record` 包，aacLc → m4a 不转码；误触（<500ms / 没文件）判为丢弃 |
| `capture/submit.ts` | `capture/submit.dart` | ✅ 先写文件、再插行；来源由「手里真有什么」定（图 > 音 > 文）|
| `app/card/[id].tsx` 的音频段 | `ui/audio_player.dart` | ✅ **RN 只是把路径印出来**，这里能听了 |
| `expo-network` 的 `useNetworkState` | `platform/network.dart` | ✅ 无网时录入坞上方提示「先拍照或打字」 |
| `app/card/[id].tsx` 的照片条 | `ui/media_view.dart` 的 `openImageViewer` | ✅ **同一卡片的多张照片，点开后能左右滑着看**；RN 那边**连点开都没有**（只是一排缩略图）|

⚠️ **全屏相册：真机报「同一个卡片中的两张图不能左右滑动切换」（2026-09-22 修）**

原来那个全屏页只收**一个** `relPath`，想看第二张只能**退出去、再点第二张缩略图**
—— 那不是少个手势，是条死路。现在一次拿到整组 + `initialIndex`（**从点的那张开始**，
不是每次都从头），用 `PageView` 翻页，标题给出「2 / 3」。
只有一张时不显示页码（没有可翻的页，数字只是噪音）。
卡片详情里那句 `N 张 · 点开可左右滑` 是**必需的**：翻页手势没有视觉提示，
不写出来就等于没做。

**两个踩到的坑（都写进代码注释 + 用例了）**：

1. ⚠️ **每一页都要用 `SizedBox.expand` 铺满，别用 `Center` 直接包 `Image`。**
   图片还没解码完时 `Image` 的固有尺寸是 **0**，`InteractiveViewer` 会跟着变成 **0×0**，
   于是「在图上拖动」根本落不到它身上 —— 页面看着正常、就是划不动。
   铺满后 `BoxFit.contain` 自己会居中按比例装进去，两边留黑边反而更像相册。
2. ⚠️ **`InteractiveViewer` 并没有吃掉翻页手势** —— 别再往这个方向查一遍。
   我一开始就是这么怀疑的，去读了 `ScaleGestureRecognizer` 才确认不成立：
   它要 **`kPanSlop`(=36px)** 才接受，而 `HorizontalDragGestureRecognizer` 只要
   **`kTouchSlop`(=18px)**，翻页永远先赢。
   真正的原因是**我的用例用了 `tester.drag` 拖整整半页、收尾速度为 0**，
   而 PageView 恰好在半页处**回弹** ⇒ 「明明划了却没翻页」是**测试造出来的假象**。
   **改成 `tester.fling(..., 速度 900)` 就够了。**
   > 通用教训：`tester.drag` 收尾速度是 0，凡是靠**惯性**翻页/滚动的东西
   > （PageView、ListView 的甩动）都得用 `fling`，否则会得到一个「像 bug 的测试」，
   > 然后去改一段根本没坏的代码。

⚠️ **`image` 包埋的两个雷（都只有实测才会发现，都已被测试钉住）**：

1. **`encodeWebP` 默认 `lossless: true`，而无损模式下 `quality` 被完全忽略。**
   只写 `encodeWebP(x, quality: 80)` 会得到一个「参数看着对、体积大一倍以上、
   且毫无报错」的**无损**文件。包自己的源码注释就写着
   「`encodeWebP(image, quality: 40)` on its own does nothing at all: pass `lossless: false` first」。
   测试用「同图无损 vs 我们的输出」的体积差把它钉死了。
2. **EXIF 方向已经由 JPEG 解码器烤进像素了 —— 别自己再补一次。**
   `decodeImage(jpeg)` 出来的对象 `exif` 是空的，看着像漏读了方向，很容易顺手补一刀
   （`decodeJpgExif` 取回方向 → 赋给 `decoded.exif`）。**那会把照片转两遍**：
   `_jpeg_quantize_io.dart` 解码时就读了方向、转了像素、并**把 orientation 清成 null**
   —— 这正是「exif 是空的」的原因。实测 1200×600 的竖拍照会变成 600×1200 又转回 1200×600。
   `bakeOrientation` 保留着，因为 **PNG 的 `eXIf` 分块**那条路确实需要它（对已转正的图是空转）。

⚠️ **一处与 RN 的刻意分歧：拍照用系统相机，不是应用内取景器。**
RN 的 `CameraModal.tsx` 是 `expo-camera` 的自绘取景器。这里改用 `image_picker` 调系统相机，
理由是**风险不对称**：自绘取景器要自己拥有一套相机会话的生命周期（权限、预览比例、旋转、
前后台切换、多 ROM 差异），而这些东西**只有上真机才知道写没写对** —— 本机既没有 Android SDK
也没有真机，等于闭着眼写；系统相机由 OS 提供，几乎不可能出岔子。
代价是「每拍一张要回一次 App」。**需求 173 的两条（不限张数 + 构图引导）因此挪到录入坞上**：
拍完回来就看到「已拍 N 张（不限张数）+ 第一张拍全貌 → 再拍局部 → 最后特写」，
旁边一颗「再拍一张」接着拍。**哪天要做真·取景器连拍，只需改 `photo_picker.dart` 一个文件。**

⚠️ **Android 清单只改了两处**（`android/app/src/main/AndroidManifest.xml`）：
`android:label` 从 `findr_app` 改成 `Findr`（用户看到的 App 名）；
**权限一条都没自己写** —— `RECORD_AUDIO` 由 `record_android` 的清单合并进来，
`ACCESS_NETWORK_STATE` 由 `connectivity_plus` 合并进来。**刻意不声明 `CAMERA`**：
一旦声明了，`image_picker` 反而会被要求先拿到该权限才能用。

⚠️ **包体积代价（第九轮实测）**：APK 从 18.2MB 涨到 **22.1MB**（+3.9MB）。
解压后的大头：`lib/arm64-v8a/libflutter.so` **11.7MB**（引擎，版本固定就不变）+
`lib/arm64-v8a/libapp.so` **7.7MB**（我们自己的 Dart 代码，**会随后续功能继续涨**）+
`lib/arm64-v8a/libsqlite3.so` 1.7MB。涨的 3.9MB = 新依赖的 Dart 代码进 `libapp.so`
+ 它们的原生 / AndroidX 代码进 `classes.dex`。
包里另有 `lib/armeabi-v7a/libdartjni.so`(81KB) 与 `lib/x86_64/libdartjni.so`(117KB)
两个**非 arm64 残留** —— 它们来自 **`path_provider_android`**（第八轮就有的依赖，
**不是本轮新增**），合计约 200KB，**不值得为它加 `abiFilters`**。

**平台层至此写完（7 个模块，约 1,000 行）** ⇒ UI 之前再无「接线要补」的欠账。
三条容易写错的语义，写在代码注释里，这里再点一遍：

- `platform/backup.dart` 的挑文件**必须** `FileType.any`；导出只留最近 3 个、落在临时目录。
- `platform/runtime.dart` 的 `runSearch` 在**没配模型时不抛错**，把 `llm`/`cfg` 传 `null`
  让 core 走字面兜底 —— 抛了连兜底都没了，而兜底正是没配模型时唯一能用的东西。
- `visionSupported` 只在「探测过 · 明确不支持 · 模型名没变」三件同时成立时才锁死；
  **没探测过一律按可用**（需求 3.3 是「能力缺失时降级」，不是「未探测时禁用」）。

**媒体与自检这三条关键口径（都在代码注释里）**：

1. ⚠️ **`MediaIo.audioPart` 必须走 `MultipartFile.fromPath`**（文件流），
   **别把 m4a 整个读进内存** —— 这是 TS 原注释明确要保住的性质。
   且要**尊重调用方给的 `filename`**：RN 那边被 FormData 吃掉了这个名字，
   而服务端常靠后缀嗅探格式。
2. ⚠️ **设备层自检「跑不了」要单独成态**（`DeviceSelfCheckUnavailable`），
   **不能塞一条红项**。否则这一屏在 `flutter test` / CI 里永远是红的，久而久之没人看。
   同一个道理：`AppPaths.ready == false` 时核心组退回内存库，并在标题里**写明跑在哪**。
3. ⚠️ **自检要能被反复点击**：临时表先 `DROP ... IF EXISTS`、探针文件跑完即删、
   跑完把库里的 `__findr_*` 清干净。它是个「随时可以点开看看」的屏，不是一次性脚本。

**设备层已从「只能上真机才知道」变成有自动化覆盖**：`apps/flutter/test/device_selfcheck_test.dart`
（6 个用例）把沙盒根目录钉到临时目录上（`AppPaths.initWith`），于是真实库文件、媒体往返、
整库打包往返都在 `flutter test` 里跑。其中一条专门验「检查不是空转」：
内存库上 PRAGMA 那一项**必须**报错（journal_mode 是 memory 而非 wal）。

⚠️ **但它仍不能替代真机**：Android 的文件系统语义、以及随 APK 发布的那份 SQLite，
只有真机上才算验过。

---

## 7. 环境现状（本机实测，2026-09-21）

| 项 | 状态 |
|---|---|
| **Flutter SDK** | ✅ **已装**：**3.47.5 stable · Dart 3.13.4**，实测通过（装法见 §7.1）|
| **Android SDK** | ⬜ **未装，可以先不装**（`ANDROID_HOME` 为空；`%LOCALAPPDATA%\Android` 只有 platform-tools）|
| **出包方式** | ✅ **仍走 CI**（`mos1128/findR` 的 GitHub Actions，**flutter job 待加**）|
| 本机已有 | Node 22 / pnpm / Python 3.13 / `gh` CLI（**已登录**）/ `adb`（不在 PATH）/ **scoop** |

### 7.1 为什么 Flutter SDK 必须装（2026-09-21 用户提问后定案）

**「出包」这一半确实可以继续全交 CI，但「验收」这一半不行。**

- **可以交给 CI 的**：`flutter build apk` 跑在 GitHub Actions 上（`subosito/flutter-action`），
  本机不需要 Android SDK。这一点和 RN 时代一样，**不变**
- **不能交给 CI 的**：本次迁移的核心手段是「**逐块翻译 + 181 个用例当验收网**」，
  即 **改一行 → 立刻跑测试看有没有译错**。没有本地 SDK ⇒ 每轮「改一行」都要
  push → 等 20+ 分钟 CI → 翻日志；181 个用例走一遍，时间全消耗在等构建上
- **命门本身也要本地验**：§6.1 那条 FTS5 + trigram 是一次**约 30 秒的本地实验**，
  放 CI 里就是 20 分钟一轮
- 第 8 节那条「**别在没有设备反馈的情况下假定 UI 是好的**」—— 这次 UI 是重写，更需要本机跑

**结论：Flutter SDK 必装；Android SDK 可以等 V1 要上真机时再装。**

| 想做的事 | 要装什么 | 大概体积 |
|---|---|---|
| 写 Dart、跑测试、验 FTS5/trigram | **只要 Flutter SDK**（自带 Dart + analyzer + test runner）| ~1GB，约 10 分钟 |
| 本机出 APK / 连真机 `flutter run` | 再加 Android SDK + JDK | ~5GB |
| 只想看 UI 效果 | `flutter run -d chrome`（**相机 / 录音等插件在 web 上不可用**）| 0 |

**装法（本机已核实）**：scoop 的 `extras` 桶里就有 —— `scoop install flutter`。

#### 7.1.1 版本锁定策略（2026-09-21 定，三层各司其职）

| 层 | 做法 | 状态 |
|---|---|---|
| **本机** | **`scoop hold flutter`** ⇒ 冻结在 **3.47.5**，连 `scoop update *` 都不动它 | ✅ 已执行 |
| **CI** | workflow 里**写死 `flutter-version: 3.47.5`**，**绝不写 `channel: stable`** | ✅ **已执行**（`.github/workflows/flutter.yml`）|
| **仓库** | 版本号记在本文件；**先不引 FVM** | ✅ 本条即为记录 |

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
  下次 `scoop update` / 卸载时会出乱子。**要换版本一律走 scoop。**

### 7.2 装完之后的实测结果（2026-09-21 核实）

**版本与体积：**

- `flutter --version` ⇒ **Flutter 3.47.5 · channel stable** · framework revision `6a19cca564`(2026-09-17)
- `dart --version` ⇒ **Dart SDK 3.13.4 (stable) · windows_x64**
- **解压后 3.3 GB**（压缩包 1.9 GB 留在 `scoop\cache\` 里，可 `scoop cache rm flutter` 回收；
  **用户 2026-09-22 明确表示不回收** —— 不影响使用，重装时 scoop 会重新下）
- ⚠️ **别把 3.3 GB 和 App 体积混为一谈**：这是**开发期工具**，装在开发机上、**不进包**。
  APK 里装的是**预编译 engine（按 ABI 各几 MB）+ 自己的 Dart 代码**，与 SDK 体积无关。
  App 体积只由 ① 打包哪几个 ABI ② 引入的原生库决定。

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
（这正是铁律 5 的同类问题：**「检查器跑不起来」≠「能力不支持」**。）

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
  **那是沙箱限制，不是环境问题**。
- ⚠️⚠️ **沙箱里跑 `flutter test` 之前必须摘掉代理环境变量**（2026-09-22 踩到，卡了一轮）：
  沙箱里设着 `http_proxy=http://127.0.0.1:<port>`，而 **Dart 的 WebSocket 客户端也读这个变量**
  ⇒ `flutter_tester` 与本机测试进程之间的回环连接被塞进代理，报
  `Unable to connect to flutter_tester process: WebSocketException: Invalid WebSocket upgrade request`。
  **这个报错看着像 Flutter 坏了，其实是代理**。修法：

  ```
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
  export NO_PROXY="127.0.0.1,localhost" no_proxy="127.0.0.1,localhost"
  ```

- ⚠️ **给 `findr_core` 加了新依赖后，`apps/flutter` 的锁是陈旧的**（2026-09-22 踩到）：
  `apps/flutter/pubspec.lock` 与 `.dart_tool/package_config.json` 是 `flutter create` 那次留下的，
  **path 依赖新增的传递依赖不会自动补进来** ⇒ `flutter test` 编译 `findr_core` 时报
  `Method not found: 'Request'.` / `Undefined name 'MediaType'` 一大片（看着像 core 写错了）。
  **`flutter pub get` 一次即可**。⚠️ 注意 **`flutter analyze` 当时是「No issues found」**，
  所以**「analyze 过了」不代表依赖是对的** —— 改完 core 的 pubspec 一律补跑 `pub get`。
- **`flutter analyze` / `flutter test` 会连带分析 path 依赖的整个 `findr_core`** ⇒
  在根目录层次改 core 之后，`apps/flutter` 侧也要跟着验一遍，别只看 `packages/findr_core`。
- 📌 **`enable-native-assets` 不用管**：`flutter config --list` 显示 `(Not set)`，
  但 3.47.5 下**默认就是开的**（实测 `build/native_assets/` 有产物，见 §6.1）。
- ⚠️ **`flutter build apk --target-platform android-arm64` 产出的是 `app-release.apk`**，
  **不带 ABI 后缀**！`app-arm64-v8a-release.apk` 那种名字**只在 `--split-per-abi` 下才有**。
  第一次做 CI 出包就栽在这上面：`flutter build` 明明成功了（`✓ Built … app-release.apk (18.2MB)`），
  下一步断言却报 `No such file or directory` —— **看着像构建没产出，其实只是名字猜错了**。
  ⇒ CI 里一律用 glob 取，别赌名字。
- 📌 要**核对 CI 真的跑了**：`gh run list --workflow=flutter.yml`；
  失败看 `gh run view <id> --log-failed`。工作流**刻意不挂 push 触发 `apk`**（额度有限），
  要出包用 `gh workflow run flutter.yml` 或打 `fapk-*` tag。

---

## 8. 十二条铁律（从 RN 时代继承）

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

## 9. 用户画像与协作偏好（**读这段，能让沟通少绕很多弯**）

- **他不懂技术**（原话：「我不是太懂技术」）⇒ **讲结论要通俗、要打比方**，别堆术语；
  他会连续追问到弄明白为止，这是正常的，别嫌烦
- **他很在意体积** —— 拿自己那个 10MB 的 Tauri 网关当证据来反问过我
- **他也在意外观一致性** —— 这是他愿意换 Flutter 的主因
- **他要覆盖全部平台**：Win / macOS / Linux / Android / iOS
- **他决策果断**：想清楚就拍板，拍板后不喜欢反复（比如「先不改 ML Kit」说了就不再提）
- 他会**打断**你（问了一半改主意）—— 遇到就顺着新的来，别强行把旧问题讲完

**桌面那三份给他看的文档**（`C:\Users\mos\Desktop\findr-功能全景.md` / `-场景手册.md` / `-测试清单.md`）：
内容描述的是 **RN 版**的行为。**产品行为不变（需求没变）所以大体仍成立**，
但**凡涉及界面与操作路径的描述都要按 Flutter 版逐条重校**。
出包后要**刷标题与包名到新 tag**（这是老规矩）。
