# Findr · Flutter 交接

> **本文件是新会话的第一份必读，也是唯一权威。**
> 历史：2026-09-21 从 React Native (Expo) 迁到 Flutter；**2026-09-23 迁移收尾 ——
> 旧版 RN / TS 代码已整块删除**（`apps/mobile` + `packages/core` + pnpm/tsconfig 工具链），
> RN 期的《开发交接.md》也一并删除。**同日还把 Flutter 工程从 `apps/flutter/` 提到了仓库根**，
> 并启用了 Dart 官方的 pub workspaces（见 §4.1）。
> ⚠️ **需要查旧实现**：`git show ad93100:<路径>`（`ad93100` = 删除前最后一个提交）。
> Dart 代码里大量注释写着「逐字对应 `packages/core/src/xxx.ts`」—— 那些是**移植出处**，
> 源文件已不在工作区，别去仓库外面找。

---

## 0. 新会话启动顺序（照做）

1. 读**本文件**全文
2. 读 `需求.md` —— **产品规格，最高权威**
3. 读 `技术设计.md` —— 数据模型、算法、判定标准
4. 看 **§0.2** —— 那里是「一期的全部剩余」，比任何进度叙述都准
5. §4 那 5 个决策**已全部定案，别再重新讨论**；§6 是已完成部分的过程记录，按需查

### 0.1 当前状态快照（2026-09-23）

| 项 | 状态 |
|---|---|
| 5 个开工决策 | ✅ 定案（§4）|
| **旧版 RN / TS 代码** | ❌ **2026-09-23 整块删除**（`apps/mobile` + `packages/core` + pnpm / tsconfig 工具链 + RN 的《开发交接.md》），**用户拍板，不是误删**。要查旧实现：`git show ad93100:<路径>` |
| Flutter SDK | ✅ 3.47.5 stable / Dart 3.13.4；本机已 `scoop hold` 冻结版本（§7）|
| 骨架 | ✅ **Flutter 工程就在仓库根**（applicationId `com.findr.app.dev`）+ `packages/findr_core/`；两者用 **pub workspaces** 统一解析（2026-09-23 调整，见 §4.1）|
| **命门（FTS5 + trigram）** | ✅ 第 1 层（`dart test`）· ✅ 中间层（`flutter test`，Flutter 工具链下 native assets 真编出了 SQLite）· ✅ **第 2 层（真机，2026-09-22 用户实测：自检两组全绿）** ⇒ **三层全部通过，整套检索方案成立** —— 见 §6.1 |
| **core 翻译** | ✅ **译完**：5,394 / 5,429 行 ≈ 99.4%（余下 35 行是 TS 的 `src/index.ts` 桶文件，Dart 用 `findr_core.dart` 代替）⇒ 过程明细见 §6.2 |
| **应用层接线** | ✅ **7 个模块全写完**（约 1,000 行）：`app_paths` · `db` · `media` · `device_selfcheck` · `secure` · `backup` · `runtime` —— 见 §6.3。**UI 之前再无接线欠账** |
| 自检屏（真机载体） | ✅ 分两组：**核心**（FTS5 命门，优先跑在真实库文件上）+ **设备层**（PRAGMA / 外键 / 嵌套事务 / 媒体往返 / 打包往返）。**入口已从 `main.dart` 挪到「设置 → 维护」**（`main.dart` 的 `home` 现在是记忆流主页）⇒ **APK 装好，进设置点「自检」即可验命门第 2 层** |
| 验收网 | `dart analyze` / `flutter analyze` 均无问题 · `dart test` **290 通过** · `flutter test` **90 通过**。⚠️ **TS 侧的 `pnpm check` 基线已随 TS 代码一起废除**，别再去找它。⚠️ core 从 296 降到 290 是删掉评测样本结构测试的结果，**不是测试被削弱**（见下一行）|
| **离线跑分线** | ❌ **2026-09-23 整条废弃**（用户拍板）：原先在本机网关上对着 20 条自造样本算出的那 8 个准确率 / 延迟指标，**不再作为验收手段** —— 样本是自己推演的、模型跑在本地、评分口径也是自己定的，跟真机实际使用差得远。**模型好不好用，靠用户自己用出来。** 样本 `test/fixtures/samples.dart` 与其结构测试已删，口径变更记在 `测试计划.md` 开头 |
| `findr_core` 依赖 | `sqlite3 ^3.6.0`（DB）+ **`http ^1.2.0` / `http_parser ^4.0.0`（`providers/` 联网，对应 TS 的 `fetch`）**|
| app 依赖 | `findr_core` · `path_provider` · `flutter_riverpod` · `http` · `http_parser` · `flutter_secure_storage` · `share_plus` · `file_picker` · `package_info_plus` · **`image`**（压缩到 WebP）· **`image_picker`**（拍照/相册）· **`record`**（录音，m4a/AAC）· **`audioplayers`**（回放）· **`connectivity_plus`**（无网提示）|
| CI | ✅ `.github/workflows/flutter.yml` **唯一一条流水线**（`checks` + `apk`；**版本写死 3.47.5**）。`apk` 每次都对**产物本身**断言 `libsqlite3.so` 含 `fts5`/`trigram`、合并清单含 `INTERNET`，最后发 `flutter-dev-latest`（当前包约 22.2MB）|
| 品牌素材 | ✅ RN 的图标 / 启动图已搬到 `assets/branding/`（**尚未接入**，属发布收尾那一步；参数也记在那边了）|
| **界面 + UI 重构** | ✅ 界面写完（22 个文件，**没照抄 RN**；`flutter test` 8 → 83）· ✅ **UI 重构一版（2026-09-23，用户真机验收通过）**：配色换冷灰系、卡片改阴影浮起、录入口重写成微信式输入栏 —— 明细见 §6.3。**拍照 / 连拍 / 相册 / 长按录音 / 音频回放 / 全屏相册左右滑全部接上** |

### 0.2 「一期 = 安卓版」的全部剩余（2026-09-23 更新）

⚠️ **用户 2026-09-22 明确：一期只做安卓版**，V2 / V3 / Linux 全算后续。
一期 ≈ `技术设计.md` 的 **M1 录入 + M2 检索 + M3 管理 + M4 备份** 四个里程碑 ⇒ **下表就是一期的全部剩余**。

| 组 | 项 | 状态 |
|---|---|---|
| **A 验收** | **真机最小验收 7 条**（`测试计划.md` §**一.1**）| ✅ **2026-09-23 全部走完**（用户逐个回报：①~⑦ 全过）。第一条就撞出一个 release-only 的真 bug（缺 `INTERNET` 权限 ⇒ 域名解析失败，已修 + CI 加闸，见 §6.3）。<br>⚠️ **只剩一条待复验**：2026-09-23 新增「备份带上 API Key」，**下次装新包时要重走 ⑥⑦**（换机后 Key 应自动恢复）。明细与逐条结果见 `最小验收清单.md` |
| | ~~`需求.md` §十 的 8 个验收指标~~ | ❌ **2026-09-23 用户拍板：这条不做了**。原先那批数（可解析率 100% / ask 16.7% / 召回 94.4% / L1 延迟 P95 14.7s）是在本机网关 + 20 条自造样本上跑出来的，**跟真机实际使用差得远 ⇒ 不作为验收手段**。模型好不好用靠用户自己用出来，见 §0.1「离线跑分线」与 `测试计划.md` 开头 |
| | M1 验收（三类卡各一张 · 飞行模式素材不丢）| ⚠️ 属最小验收 ② ④ |
| | M3 验收（位置改名后检索仍命中）| ✅ 不算欠账：纯 core 逻辑，`dart test` 覆盖（原 16 步第 8 步已从最小清单砍掉）|
| | M4 验收（换机：导出 → **卸载** → 重装 → 导入）| ✅ 属最小验收 ⑦，**已过**（2026-09-23）。⚠️ 带 Key 的那版还没上过真机，下次复验 |
| **B 功能欠账** | **后台自动补跑**（M2 明列：技术设计说「Android 的 BackgroundFetch 推到 M2」）| ⬜ **没做**。现状只有「App 回前台时补跑」（`memory_stream_screen.dart:62`）。⚠️ 技术设计自己标了 **best-effort、验收不依赖** |
| | **gemini 适配器**（M2 明列）| ⬜ **没做**。`core/providers/` 只有 `anthropic` / `openai_compat` / `fake`。**只有你打算用 Gemini 才需要** |
| **C UI 重构** | 重构一版 | ✅ **2026-09-23 完成，且用户已在真机上验收通过**（配色 / 组件库 / 三主界面 + 录入口改微信式输入栏，明细见 §6.3 末段）|
| **D 发布** | **应用图标 + 启动图** | ⬜ **现在还是 Flutter 模板默认**（`mipmap-*/ic_launcher.png` 441~1443 字节）。✅ **素材已备好**：`assets/branding/`（`icon.png` · `android-icon-{foreground,background,monochrome}.png` · `splash-icon.png`，**参数与两种接入方式写在该目录的 README 里**）|
| | **换正式签名** | ⬜ 现在 release 签 **debug 证书**（`android/app/build.gradle.kts:38`，CI 里还有一道 Guard 挡模板漂移）|
| | 版本号 | 🟡 现为 `0.1.0+1`（与 RN 的 `0.1.0` 一致）—— 正式发前定 |
| | 正式发版方式 | ⬜ 未定 |
| **已完成** | 功能面（`需求.md` §十一 MVP 8 条）| ✅ 已逐条核实齐（含 L3 三档 · `未分析` 角标 + 补分析 · `待转写` + 批量补转写 · L1「已放宽条件」提示）|
| | 命门三层 + 真机自检 | ✅ 全过（§6.1）|
| | 明文备份两道闸（红条 + 导出确认框）| ✅ 已做 ⇒ **换签名那道闸已打开**（见下）|
| | `需求.md` 标「后续版本」的 8 项 | 🚫 **不算欠账**：单卡分享 · 提醒机制 · 记忆生命周期 · 冷启动引导 · 房屋档案 · 多物品拆卡 · 本地 embedding · 安全保险箱 |

⚠️⚠️ **换签名的顺序不可颠倒**（`技术设计.md` §「签名现状与代价」）：
换正式 keystore 后**与旧包无法覆盖安装、必须卸载**，而记忆库只在手机上 ⇒
必须「**先导出备份 → 存到 App 之外（微信/文件）→ 再卸载 → 重装 → 导入**」。先卸载就是丢数据。
原设计说「换签名要与 M4 同批做」—— **M4 已完成 ⇒ 现在可以做了**。

⚠️ **回答「一期做完了吗」的正确口径（2026-09-23 晚更新）**：
**功能面齐 + 真机 7 条验收全过 + UI 重构一版（也已真机过）⇒ 一期只剩 D 组（发布收尾）。**
D 组 = **应用图标 / 启动图 · 换正式签名 · 定版本号 · 定发版方式**。
⇒ **准确说法**：「功能、验收、UI 都过了；**只剩发布收尾**，做完才算一期完成。」
别把「验收通过」说成「一期完成」，也别把「能装能用」说成「开发完成」。

**几条 git 现状（2026-09-21 实测，别重复排查）**：

- 远端仓库 `mos1128/findR` **可达**；出包标签统一落在 `flutter-dev-latest`（滚动的，每次覆盖）。
  （RN 时代的 `apk-*` 标签已成历史 —— 源码 2026-09-23 已删。）
- ⚠️ **沙箱里 `.git/refs/remotes/origin/` 建不起来** —— `git fetch origin` 会报
  `new branch main -> origin/main`、`FETCH_HEAD` 也确实写了，可 `refs/remotes/origin/main`
  **就是不落盘**；连 `git update-ref` 都返回 0 却无效，手动 `mkdir` 出的目录会被回滚。
  **不影响 push 与打 tag**（`refs/heads` / `refs/tags` 可正常写入），
  **核对远端直接用 `git ls-remote origin main`**，不需要那个引用。
  真要修就在**用户自己的终端**里跑一次 `git fetch origin`，一条命令的事。
- **出包 / 装机口径（2026-09-23 用户环境已变）**：用户本机**已有 Android 环境**，并已用
  **无线调试 + 热更新**在自己手机上装过新版 ⇒ **不必再走「CI 出包 → 传 APK → 手动安装」那条老路**。
  CI 的 `apk` 作业仍保留，用途变成「发 `flutter-dev-latest` 供分发」+「对产物做断言」。
  包的固定属性：包名 `com.findr.app.dev` · `android:label="Findr"` · debug 证书签名（⇒ **可覆盖安装、数据保留**）。
  ⚠️ 桌面上的 `findr-flutter-dev-2026*.apk` 都是历史留档，**别拿旧包来判断当前状态**。

---

## 1. 用户拍板的路线（2026-09-21，原话转述）

> 「第一版先出安卓端，然后第二版再出 win 端，然后第三步再出 macOS 和 iOS」

| 版本 | 平台 | 定位 |
|---|---|---|
| **V1** | **Android** | 先跑通整条链路，验证技术选型 |
| **V2** | **Windows** | 桌面第一站 |
| **V3** | **macOS + iOS** | Apple 系一起（都要 Mac 构建，正好一批做）|

**节奏是「一版一版出」，不是一次全上。每版都要能独立跑通、能出包。**

⚠️ **范围澄清（用户 2026-09-22 明确）**：**一期只做安卓版** —— V2 / V3（及 Linux）都是**后续工作**，
不进「一期做完没做完」的口径。**一期剩余清单见 §0.2。**

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

## 3. 迁移的真实工作量（2026-09-21 实测，**已全部完成**）

> ⚠️ 表里的 `packages/core` / `apps/mobile` 已于 2026-09-23 删除 ——
> 这些数字是当时的实测规模，留作「这次迁移到底有多大」的记录。

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

**这不是"重新设计"，是"翻译 + 换壳"。** 当时有 181 个 TS 用例当验收网（如今是 Dart 侧 290 + 90），译错了会立刻被抓住 ⇒
**迁移风险比行数看起来低**。

⚠️ 有个工具迁移后**没用了**：`.workbuddy/tools/probe-hbc-strings.py`（解析 Hermes 字节码字符串表）——
Hermes 是 RN 的 JS 引擎，Flutter 是 AOT 编译、没有它 ⇒ **该工具已于 2026-09-23 随 RN 代码一并删除**，别再找它。
但 **APK 拆解手法**（用 Python `zipfile` 按产物结构断言）**仍然有用** ——
CI 里那两道产物级断言（`libsqlite3.so` 含 fts5/trigram、合并清单含 INTERNET）就是这套手法的延续。

---

## 4. 开工前的 5 个决策 —— ✅ **已于 2026-09-21 全部定案**

**这 5 个已经定了，别再重新讨论。** §4.1 / §4.2 由用户拍板，§4.3 / §4.4 / §4.5 按推荐执行。

### 4.1 ✅ Flutter 工程放哪 —— **同仓，且就在仓库根**（用户定；2026-09-23 收窄）

原始理由（2026-09-21）：

- 迁移期最大的需求是**随时对照 TS 源码** —— 同仓最方便，改一行 TS 就能旁边看 Dart
- **旧 RN 版还能继续出货**（万一 Flutter 卡住，有退路）—— 这条退路 2026-09-23 用不上了（§4.2）
- `.github/workflows/` 里**加一个 flutter job，老的 android job 先留着** —— 老 job 也已删除

**当前目录结构（2026-09-23 最终版）**：

```
findR/                             ← 仓库根就是 Flutter 工程本身
├─ lib/                            ← UI + 平台接线（新设计，**不照抄 RN 界面**）
│  ├─ platform/                    ← 相机 / 录音 / 安全存储 / 文件 / 分享（Flutter 插件实现）
│  ├─ capture/ state/ screens/ theme/ ui/ selfcheck/
├─ test/                           ← widget + 设备层测试（90 条）
├─ android/                        ← V1 只有安卓
├─ assets/branding/                ← 图标 / 启动图素材（D 组发布收尾用）
├─ pubspec.yaml                    ← `findr_app`，**同时是 workspace 根**（里面写了 `workspace:`）
├─ pubspec.lock · .dart_tool/      ← ✅ 全仓唯一一份（pub workspaces 的产物）
├─ packages/
│  └─ findr_core/                  ← 新 Dart core（**纯 Dart，零 Flutter 依赖**）
│     ├─ lib/{db,search,providers,parse,pipeline,backup,prompts,util,media,cards}/
│     ├─ test/                     ← 290 条，`dart test` 直接跑
│     └─ pubspec.yaml              ← 声明 `resolution: workspace`；依赖 `package:sqlite3` + `package:http`
└─ .github/workflows/flutter.yml   ← 唯一流水线
```

> **为什么不再有 `apps/`**（2026-09-23）：`apps/` 是 RN 期的分层 —— 当时 `apps/mobile` 与
> `apps/flutter` 并存，那层才有意义。RN 删掉后 `apps/` 下只剩一个孩子，这层就空了。
> 现在只有一个 app，**仓库根直接就是它** —— 这正是 `flutter create .` 的默认形态，
> 也是最常见的单 app 仓库样子。
> ⚠️ 如果将来真要有第二个**独立** app（桌面端等），那时再搬回 `apps/` + `packages/` 两层也不迟。

**三条关键设计点（别改）：**

1. **Dart core 做成独立 package，不要塞进 app 的 `lib/` 下** —— 它是纯 Dart，
   可以用 `dart test` 直接跑，不必起 Flutter 环境、不被 widget 测试拖慢；
   **V2/V3 桌面版复用同一个 core**，不用复制。
2. **数据库依赖只有一层**：`findr_core` 依赖 **`package:sqlite3` 3.x**，就这一条。
   它**自带预编译 SQLite** ⇒ **app 端不用再补任何 native 库依赖**，
   **连本机的 `sqlite3.dll` 都不用准备**。（此前「core 用 sqlite3 + app 加 `sqlite3_flutter_libs`」
   的设计**已作废**，见 §4.5。）
   （后来又加了 `package:http` + `http_parser` —— 那是**联网**那条线，与 DB 无关；
   它同样是 Dart 官方包、纯 Dart、无 native 依赖，不破坏「app 端不用补 native 库」这条。）
3. **名字用 `findr_core` 而不是 `core_dart`** —— Dart 包名必须 snake_case，
   且这样能与当年的 `packages/core`（TS 老版）一眼区分（那个包已于 2026-09-23 删除）。

**工程约定（2026-09-23 更新）：**

- **依赖用 Dart 官方的 pub workspaces 统一解析**（`dart.dev/tools/pub/workspaces`，Dart 3.6+ 起）：
  根 pubspec 声明 `workspace: [packages/findr_core]`，成员包声明 `resolution: workspace`。
  ⇒ 全仓**只有一份 `pubspec.lock` 和 `.dart_tool/`**（都在仓库根）；在根跑一次
  `flutter pub get` 就把两边都解析了，`findr_core` 也不必再写 `path:` 依赖、按名字引用即可。
  - ⚠️ **必须用 `flutter pub get`**，不是 `dart pub get` —— app 带 Flutter SDK 依赖，纯 dart 的 pub 解析不了。
  - ⚠️ pub get 会**自动删掉**成员包里「游荡的」`pubspec.lock` / `.dart_tool/`，**别手动建回去**。
- `.gitignore` **只有仓库根一份**（Flutter 模板的条目已并进去）；
  `build/`、`.dart_tool/`、`android/local.properties`、`*.iml`、`.idea/` 都不进版本库。
- **CI 里的 Flutter 版本号写死成与本地相同的具体版本**（不要写 `channel: stable`，见 §7.1.1）。

### 4.2 ✅ 旧 RN / TS 项目怎么处理 —— **2026-09-23 整块删除**（用户改判）

- 原决策（2026-09-21）是「**保留，不删**」—— 定位是**参照实现** + **回滚路**，用户原话「旧版保留方便对照」。
- **2026-09-23 用户改判：全部删除。** 这个改判站得住：迁移已实质完成（core 译完 + 界面 + UI 重构
  都过了真机），「参照 + 回滚」的价值已被「Flutter 版自己能跑通」取代；
  而且**删除 ≠ 丢失** —— 源码完整躺在 git 历史里（删除前最后一个提交 `ad93100`，
  `git show ad93100:<路径>` 可取回）。
- 删除范围：`apps/mobile` · `packages/core` · pnpm / tsconfig 工具链 · RN 的《开发交接.md》。
  ⚠️ **只有图标素材被抢救出来**，留在 `assets/branding/`（发布收尾要用，见 §0.2 D 组）。
- ⚠️ **副作用**：Dart 代码里 60 多处「逐字对应 `packages/core/src/xxx.ts`」的注释，
  现在指向的是**历史出处**而不是活文件 —— 这是有意保留的（它记录了移植来源与对照行数），
  **不是漏改**，别再顺着这些路径去找文件。

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

### 5.1 现有文档（口径互相牵连，**改一处要 grep 全捞**）

| 文件 | 作用 |
|---|---|
| `需求.md` | **产品规格，最高权威** |
| `技术设计.md` | 数据模型、算法、判定标准 |
| `场景分析.md` | 各字段的使用场景 |
| `prompt设计.md` | 提示词设计（落地在 `findr_core/lib/prompts/templates.dart`）|
| `测试计划.md` | 真机验收步骤（最小验收 7 条 + 完整 16 步 + 备份专项）|
| `最小验收清单.md` | 真机最小验收 7 条（**已全过**，下次只需复验 ⑥⑦）|
| **本文件** | Flutter 时代的交接权威（铁律 / 环境坑 / 用户口径都在这里）|

（RN 时代的《开发交接.md》已于 2026-09-23 删除；它的铁律与环境坑已收进本文件 §7 / §8。）

### 5.2 几个「当初对着 TS 敲定的规格」要点（源码已删，这里留结论）

- **建表 / 迁移**（原 `db/schema.ts`）：⚠️ **SQLite 删列必须重建整张表**；DDL 刻意拆成
  「一条 DDL = 一个数组元素」（原 TS 侧是因为 op-sqlite 只能执行多语句的第一条，Dart 沿用同一形状）
- **仓储**（原 `db/repository.ts`，648 行）—— core 里最大的单文件，全部 CRUD 在这里
- **L3 整库清单 + 相关性打分**（原 `search/inventory.ts`）：`INVENTORY_POOL = 2000`；
  `scoreCard` 字段权重 **entity 6 / tags 4 / category 3 / path 2 / body 1**，≥4 字 ×2；
  **全 0 分时退化回 `created_at DESC`**
- **模型调用**（原 `providers/anthropic.ts`）：认证**默认 `authorization: Bearer`，
  仅 401/403 时自动换 `x-api-key` 重试一次**（第二十版定的，别改回去）
- **备份格式**（原 `backup/`）：`.findrpack` = `magic "FINDR"(5B) + 版本 u16(=1) + 标准 ZIP`，**明文不加密**
  （界面必须明说不加密 —— 页面红条 + 导出前确认框，这是唯一防线）
- **设置项唯一权威**（原 `settings.ts`）：`SETTINGS_KEYS`；`settings_public` 白名单是「settings 这条通道」的屏障
  —— **Key 从不走这条**。⚠️ 「备份永不含 Key」已于 2026-09-23 放开（Key 走 manifest 的可选字段 `apiKeys`，
  由平台层显式传入，**core 只搬不读**；**包是明文**，界面必须点名说清代价）

对应 Dart 实现：`findr_core/lib/` 下的 `db/schema.dart` · `db/repository.dart` · `search/inventory.dart` ·
`providers/anthropic.dart` · `backup/` · `settings.dart`。

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

`test/self_check_smoke_test.dart`（`flutter test`）。它比第 1 层多验了**一件关键的事**：
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
| 真机上跑的自检屏 | ✅ `lib/selfcheck/self_check_screen.dart`。**入口在「设置 → 维护」**（`main.dart` 的 `home` 早已换成记忆流主页，不再是自检屏）|
| 能装到真机的 APK | ✅ CI 的 `apk` 作业已多次实测出包（第九轮 **22.1MB**）。本机没装 Android SDK，出包只能走 CI |
| 产物级断言 | ✅ 该作业会从 APK 里抽出 SQLite 的 `.so`，断言二进制里**含 `fts5` 与 `trigram`**（模块按名注册，名字串会留在二进制里）。第九轮实测：`fts5` 出现 **38** 次、`trigram` **1** 次 |

⚠️ **三层各验的是不同的一份东西，别互相冒充**（铁律 5 的同类问题）：
第 1 层验桌面上的 libsqlite3、中间层验 Flutter 工具链编出来的 native assets、
第 2 层验的才是**真正随 APK 发到手机上的那份二进制**。
（第九轮出包前的产物级断言虽然能挡掉「native assets 没打进包」，
但它只证明「**编进去了**」，证明不了「**运行时跑得起来**」—— 后者才是第 2 层。）

### 6.2 core 翻译与界面（**已完成**，5,429 行口径）

| 顺序 | 模块 | 状态 |
|---|---|---|
| 1 | 骨架 | ✅ **仓库根就是 Flutter 工程**（Flutter 3.47.5，`android`，`com.findr.app.dev`）+ `packages/findr_core/`（纯 Dart，依赖 `sqlite3`）。2026-09-23 从 `apps/flutter/` 提到根 |
| 2 | `db/` 那一层 | ✅ 全部译完（2026-09-21）|
| 3 | `search/` | ✅ 全部译完（2026-09-22，含 `builder`）；顺带把它依赖的 `parse/` `prompts/` `providers/types` 一并译掉 |
| 4 | `providers/` 联网层 + `settings` + `util/` | ✅ 全部译完（2026-09-22）|
| 5 | `pipeline/` 录入编排 + `cards/` + `media/` | ✅ 全部译完（2026-09-22）|
| 6 | `backup/` `.findrpack` 导出导入 | ✅ 全部译完（2026-09-22）—— **core 到此译完** |
| 7 | 界面 | ✅ 写完（2026-09-22，**按新设计写、没照抄 RN**）+ ✅ **UI 重构一版**（2026-09-23，用户真机验收通过）—— 见 §6.3 末段 |

⚠️ 原先这里有 5 张「TS 源文件 → Dart 文件」的行数对照表，**2026-09-23 随 TS 源码一并移除**。
需要对照时：看 Dart 文件顶部的注释（写着它的 TS 出处），或用 `git show ad93100:<路径>` 取回旧源码。
**下面保留的都是翻译过程中的踩坑与有意偏离 —— 那才是有复用价值的部分。**

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
| **RN(TS) 能不能导入 Flutter(Dart) 的包** | 当时用临时 vitest 用例跑 TS 的 `importBackup`（一次性验证；TS 已删）| ✅ 2 张卡入库、位置两级、媒体 2 个、`pathNames` 与 desc 一致、无 canary |

⇒ **RN 版与 Flutter 版的备份包双向互认已实测通过**，用户的旧备份可以带过来。

**验收网**：`dart test` **289 通过**（272 + 本轮 17）、`dart analyze` 无问题；
`flutter test` **2 通过**（2026-09-22 补，含命门中间层）、`flutter analyze` 无问题；
**RN 侧 `pnpm check` 的 181 个测试（181 passed / 2 skipped）已于 2026-09-23 随 TS 代码一并废除** —— 别再把它当基线。
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

**下一块（UI）的要点**：core 已译完，**只剩 UI 没动**。UI 在仓库根的 `lib/`，
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
  谁拿到 `.findrpack` 都能读出全部记忆。**带上 API Key 时还要在确认框里点名 Key**
  （多数人听到「内容」只想到自己的卡片，不会联想到那两把密钥也在文件里）。
- ⚠️ **发布仍是测试版**（release 签 debug 证书、可覆盖安装、数据保留）；
  **功能全做完 + 重构一版 UI** 之后才正式发，**换签名放那一步**。
  ⇒ 对用户一律说「**覆盖安装、别卸载**」。
- ✅ **`ask`（补问）/ `path_suggestion`（位置猜测）已在界面上展示**（`ui/card_row.dart` + `screens/card_detail_screen.dart`）——
  需求 5.1 只要求「在卡片列表与详情页显示『想确认：…』」，**这条已满足，不算欠账**。
  ⚠️ 唯一还差的是**「一键采纳猜的位置」**：现在只印一行「模型猜的位置：…」，
  要采纳得自己去位置选择器重选一遍。`path` 的语义是「内容提到存放位置才有值」，
  **猜错比空着更糟** ⇒ 即使做，也必须是**用户点一下才应用**，绝不能默认自动填。
- ⚠️ 出网口径不变：**只往用户自填的 `baseUrl` 发请求**，别引入任何我们自己的后端。

**验收方式**：UI 没有 TS 侧的对照测试网，只能靠**真机手动过一遍**（按 `测试计划.md` 的步骤走）。
**别靠"看起来对了"。**

✅ **那笔债已还**：`P2Output` 等的手写校验已随 `parse/schema.dart` 落地（上面第 2 条）。
（`migrate_test` 里造旧库用的两处原始 SQL **不是债**：一处在填「要删的列」、一处要带
`needs_confirm = 1` —— 那些列已从仓储的列清单里摘掉，手写 SQL 正是被测的事实本身。
其余造数据与断言都已走仓储，与 TS 同源。）

### 6.3 应用层（仓库根 `lib/`）进度

（历史对照）RN 那边应用层是 `apps/mobile/src/`：`platform/`（接线）+ `app/`（路由与页面）+ `ui/` + `capture/` —— **该目录已于 2026-09-23 删除**。
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

⚠️ **Android 清单改了三处**（`android/app/src/main/AndroidManifest.xml`）：
`android:label` 从 `findr_app` 改成 `Findr`（用户看到的 App 名）；
`RECORD_AUDIO` 由 `record_android` 的清单合并进来、`ACCESS_NETWORK_STATE` 由 `connectivity_plus`
合并进来。**刻意不声明 `CAMERA`**：一旦声明了，`image_picker` 反而会被要求先拿到该权限才能用。

🚨 **但 `INTERNET` 必须自己声明（2026-09-23 真机抓到的 release-only 大坑）**：
迁移时「权限全交给插件合并」的判断**只对了一半** —— 没有任何插件会替你带 `INTERNET`，
而 Flutter 模板在 `debug/`、`profile/` 清单里自带它 ⇒ **`flutter run` 一切正常、
release 包所有域名解析失败**（`Failed host lookup`，第一台真机做验收第 ① 条时暴露）。
已修（main 清单补声明）+ 在 CI `apk` 作业加了一道「合并清单里必须有 INTERNET」的产物级闸。
⇒ **通用教训**：「权限不用自己写」这条口诀对 debug 成立、对 release 不成立；
凡是从 RN 迁移来的能力，要逐个问「RN 的权限是谁带的、Flutter 这边谁带」。

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

**设备层已从「只能上真机才知道」变成有自动化覆盖**：`test/device_selfcheck_test.dart`
（6 个用例）把沙盒根目录钉到临时目录上（`AppPaths.initWith`），于是真实库文件、媒体往返、
整库打包往返都在 `flutter test` 里跑。其中一条专门验「检查不是空转」：
内存库上 PRAGMA 那一项**必须**报错（journal_mode 是 memory 而非 wal）。

⚠️ **但它仍不能替代真机**：Android 的文件系统语义、以及随 APK 发布的那份 SQLite，
只有真机上才算验过。

**UI 重构（2026-09-23 完成，用户真机验收通过）**

范围：**只动界面层**（仓库根 `lib/` 的 `theme/` `ui/` `screens/` `capture/`），
**没碰** `packages/findr_core`、数据库 schema、`.findrpack` 格式。

| 文件 | 改动 |
|---|---|
| `theme/tokens.dart` | 换整套冷灰配色；`border` 由实色改半透明；`Radii` 新增 `xs = 4` |
| `ui/kit.dart` | Panel 去描边改**阴影浮起**；SectionTitle 加重；Chip 改实心药丸；Badge 改淡底；Notice 去掉左侧竖条；EmptyState 加圆底图标；Field / TopBar 去描边 |
| `ui/card_row.dart` | 卡片行重做 |
| `screens/memory_stream_screen.dart` | 主列表页重做 |
| `screens/card_detail_screen.dart` | 详情页重做 |
| `capture/composer.dart` | **重头**：录入口重写成**微信式输入栏** —— 左1 话筒/键盘切换 · 中 输入框或「按住说话」药丸 · 右2 ＋素材 · 右1 存 |
| `screens/settings/settings_screen.dart` | 删掉 5 条面板 hint 文案（视觉简化）|

验收：三侧基线未破（core `analyze` 干净 + `test` 290 · app `analyze` 干净 + `test` 90）；
用户已在真机上过了一遍，确认可用。

⚠️ **这次没有新增测试**（`flutter test` 仍是 90 条，与重构前同数）——
新界面靠**真机肉眼**验收，这点要清楚：以后改界面时，测试网不会替你挡住视觉退化。

---

## 7. 环境现状（本机实测，2026-09-21）

| 项 | 状态 |
|---|---|
| **Flutter SDK** | ✅ **已装**：**3.47.5 stable · Dart 3.13.4**，实测通过（装法见 §7.1）|
| **Android SDK** | ⬜ **未装，可以先不装**（`ANDROID_HOME` 为空；`%LOCALAPPDATA%\Android` 只有 platform-tools）|
| **出包方式** | ✅ **仍走 CI**（`mos1128/findR` 的 GitHub Actions，**flutter job 待加**）|
| 本机已有 | Python 3.13 / `gh` CLI（**已登录**）/ `adb`（不在 PATH）/ **scoop**。⚠️ Node / pnpm 原为 TS 侧所需，**TS 删除后已无关**；另 **2026-09-23 用户本机已装好自己的 Android 环境**（可无线调试 + 热更新）|

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

- ⚠️ **给 `findr_core` 加了新依赖后，必须补跑 `flutter pub get`**（2026-09-22 踩到；换成 pub workspaces 后同样成立）：
  当时 app 侧那份 `pubspec.lock` 是 `flutter create` 留下的，**path 依赖新增的传递依赖不会自动补进来**
  ⇒ `flutter test` 编译 `findr_core` 时报 `Method not found: 'Request'.` / `Undefined name 'MediaType'`
  一大片（看着像 core 写错了）。**`flutter pub get` 一次即可**。
  ⚠️ 注意 **当时 `flutter analyze` 报的是「No issues found」**，
  所以**「analyze 过了」不代表依赖是对的** —— 改完任一 pubspec 一律补跑 `pub get`。
  📌 2026-09-23 起走 pub workspaces：全仓只有仓库根一份 `pubspec.lock` / `.dart_tool/`，
  **只在仓库根跑 `flutter pub get`**。别再进 `packages/findr_core` 单独 pub get ——
  那会造出「游荡的」锁文件，而下次 pub get 又会把它删掉，白忙。
- **`flutter analyze` / `flutter test` 会连带分析整个 `findr_core`** ⇒
  改完 core 之后**两侧都要验**：仓库根 `flutter analyze` + `flutter test`，
  以及 `packages/findr_core` 里的 `dart analyze` + `dart test`（后者更快，先跑它）。
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

> ⚠️ **这一节原是 RN 期《开发交接.md》的第 0 节 —— 那份文档已于 2026-09-23 删除，
> 现在这里是唯一出处**（不再需要同步两处）。
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
