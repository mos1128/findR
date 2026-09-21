# findR 项目长期记忆

> 🚩 **当前方向：正在从 RN (Expo) 迁移到 Flutter** —— 用户 2026-09-21 拍板。
> **新会话先读仓库根 `Flutter迁移交接.md`**（迁移的唯一权威）。
> `开发交接.md` 是 RN 时代的历史与十二条铁律（**仍然有效**，但「1. 一句话状态 / 下一步 /
> 未验证清单 / 真机端到端验证」四节**已就地标作废**）。
> 这里只放「每次会话都要知道、且不随版本变」的东西。

## 迁移路线（用户 2026-09-21 拍板，别再问、也别自行调整顺序）
**V1 安卓 → V2 Windows → V3 macOS + iOS**，一版一版出、每版要能独立出包。
- **Linux 放最后**（用户提过要覆盖，但没排进这三版）
- **鸿蒙靠卓易通装安卓包，不为它做任何改动**
- **UI 重构直接在 Flutter 里做** —— 没有"搬旧界面"的包袱，别先照抄 RN 的界面
- 迁移工作量基线：**13,894 行**（core 5429 / 测试 3773 / 界面 4692）。
  **可直接逐字搬**：`prompts/templates.ts` + 所有 SQL 语句。**181 个用例可 1:1 译成 Dart 当验收网。**
- 第一个技术命门：**FTS5 + trigram 分词器在 Flutter 里能不能用**（必须先实测，不通则方案重估）
- 第一个障碍：**本机没装 Flutter SDK**（2026-09-21 实测 PATH 与 scoop 里都没有）
- **⚠️ 迁移开工前先 push**：**远端 `origin/main` 停在 `3aead1d`，其后的本地提交一个都没推** ——
  那些是迁移期的**参照实现 + 回滚路**（自查 `git log --oneline 3aead1d..HEAD`）。
  **push 前按铁律 8 问用户。**

## 角色与姿态
- 用户是这个 App 的**真实使用者**（在真机上天天用）。他的反馈是首手的、常带截图，
  而且**多数时候是对的** —— 2026-09-19 那次「这儿应该配置的是正确的，但是提示错误」就完全正确，
  是我们的探测在冤枉他。**先相信他，再去读代码，别先假设他填错了。**

## 发布路线（用户 2026-09-20 拍板，别再问、也别再拿旧口径推）
1. **现在：继续用测试版**（release 仍签 debug 证书，可覆盖安装、数据保留）。
   **不换正式 keystore**。
2. 等**所有功能开发完成** + 再**重构一版 UI**。
3. 那之后才作为**正式版**发布 —— **换签名放在那一步一起做**。
⇒ 「正式 keystore 必须与 M4 导出/导入同批切换」这条**约束已解除**（M4 已于 2026-09-20 做完）。
⇒ **判断「要不要重装」的旧结论一律作废**：现在就按「覆盖安装、别卸载」说，
   唯一例外是验证备份本身那一步（那需要卸载重装，且卸载前必须先导出并把备份存到 App 之外）。

## 备份：明文，不加密（用户 2026-09-20 拍板，别再当成欠账）
- 备份（`.findrpack`）**当前就是明文**：`magic "FINDR"(5B) + 版本 u16(=1) + 标准 ZIP`，
  没有口令、没有 AES、没有 PBKDF2。`需求.md` 里「本地**加密**导出/导入备份」的「加密」二字
  **暂时不成立**，加密排到后续版本。
- **别提前把加密骨架加回来**（`CryptoPort` 已删）—— 加密回归时提 `FORMAT_VERSION` 到 2、
  按版本分派；那 7 字节头存在的唯一理由就是这个判别位，**加加密之前不要动它**。
- 明文方案的两条底线：① 界面必须明说不加密（页面红条 + 导出前确认框，这是唯一防线）；
  ② `settings_public` 白名单是机密性的唯一屏障（没有加密层兜底了）。
- 回归路径与踩坑（expo-crypto 自带原生 AES、16 字节 nonce 可行、PBKDF2 必须 `pbkdf2Async` 分片）
  写在 `开发交接.md` 的「加密怎么加回来」一节，**别重新调研**。

## 权威文档（别凭记忆改）
- `开发交接.md` — 交接主文件，**推进里程碑后必须更新**，别让它过期
- `需求.md` / `技术设计.md` / `场景分析.md` / `prompt设计.md` / `测试计划.md` — 六份口径互相牵连，
  改字段或改行为要 **grep 全捞**
- 桌面 `findr-测试清单.md` — 给用户的勾选式执行单，**每次出包必须刷标题与包名到新 tag**
- 桌面 `findr-场景手册.md` — 用户视角手册，口径必须与交接文档一致

## 流程约定
1. 开工先 `pnpm check` 确认基线全绿（core 用例数见交接文档「一句话状态」）
2. 改完跑 `pnpm check` + `pnpm --filter @findr/mobile run check`
3. 出包前本地冒烟：`cd apps/mobile && npx expo export --platform android --output-dir ../../.workbuddy/tmp/dist-smokeN`
   （输出目录**别落在 apps/mobile 下**，那里不在 gitignore 里）
4. 出包链路：提交 → push main → `git tag apk-m1-fixN` → push tag → CI `android` 约 20 分钟
   **（push / 打 tag 前必须先经用户确认 —— 见铁律 8）**
5. 取包：`gh release download dev-latest --pattern '*.apk'` → 校验结构 + sha256 → 复制到桌面

## 铁律（都踩过，代价很大）
1. **文档改一处要 grep 全捞**（字段清单散在六份 md 里）
2. 「看着正常但点不动 / 看不到」⇒ 先想**层叠遮挡**（`position:absolute` / `<Modal visible>` 简写 / `zIndex`）
3. 「划不动」是**另一类** ⇒ 先看有没有滚动容器（`ScrollView` / `FlatList`）
4. 动数据库必须先写 node 测试押着，再上真机
5. **「调用失败」与「能力不支持」必须分开判** —— 判据落在「HTTP 层是否被接受」，
   不是「内容是否如期返回」。下结论前先怀疑自己的请求参数（输出上限 / 超时 / 格式）
6. **把三态结论压成布尔下发时，想清楚第三态映射到哪边，并选代价小的那一边**
   （false 的代价是关掉用户的功能，true 的代价只是白试一次）
7. **探测项只许覆盖真正在用、且能改变行为的能力** —— 加之前先问：
   **它不通过时，系统会因此少做什么？** 答不上来就别加（第十三版的「音频输入」探测是反例：
   规格里有、代码里没有、不控制任何行为，只让用户看到一句误导性的「不支持」）
8. **推送 / 打包前必须停下来，等用户明确确认「没有要改的了」**
   —— 2026-09-20 用户明确要求。一次 CI 要等 20+ 分钟，用户在手上有后续改动时
   被已触发的构建白白占掉一轮等待。**改完 → 汇报 → 等确认 → 才 push/tag。**
   这条同时适用于「改完顺手就 push」的肌肉记忆，以及把 tag 当自动收尾动作的做法。
9. **功能退役时，优先「保留列、只摘读写两侧」，不要动 schema** —— SQLite 删列必须重建整张表
   （`db/schema.ts` 顶部第 3 条），而 `NOT NULL DEFAULT 0` 的残留列零成本。
   判据是**老库与老备份必须还能读**：留一条带旧标志的 INSERT 在测试里当押注（第二十版删
   `needs_confirm` 就是这么做的）。同理，退役的判断条件才删，**它产出的数据列可以留着**。

## 技术栈决策（2026-09-21 已定，别再重新调研）
- **不换栈**（Flutter / KMP 都评估过）。四条理由见 `.workbuddy/memory/2026-09-21.md`：
  ① 「guoapp 体积小」是错觉（对方仓库 1.5M 是纯源码，我们刨掉 node_modules + `.workbuddy`
  后源码只有 2.9M）；② guoapp 的 iOS **自己 README 承认没做过 Xcode 构建、没有已签名 IPA**；
  ③ 出包绕不开原生工具链 Gradle/Xcode/NDK，Flutter 的 CI 反而给 45 分钟；④ 迁移 = core +
  界面 + 测试全部重写，换来的是「不比现在快、不比现在小、iOS 门槛一模一样」。
- **iOS 的唯一门是 Mac**，三条绕法：**EAS Build（首选，我们栈自带，免费 15 次 iOS/月，
  零改代码）** / GitHub Actions macos runner（分钟 10× 扣） / 租云 Mac。
- **鸿蒙走卓易通**（华为 iSulad 容器沙盒，能跑 APK）⇒ **安卓包已覆盖鸿蒙，不为鸿蒙做任何改动**。
- APK 瘦身：`expo-camera` 默认打包 **ML Kit 条码扫描（~5MB+，我们没用）**，
  官方开关 `expo.camera.barcode-scanner-enabled=false`，但**必须用 config plugin 写**
  （CI 是 `prebuild --clean`，手改 `android/gradle.properties` 会被冲掉）。
  **⚠️ 用户 2026-09-21 明确「先不改」，别自作主张去加。**
- **全平台（Win/macOS/Linux 也想做）**：**我们不需要一个栈管六端** —— core 零原生依赖、
  **已在 better-sqlite3（桌面）上跑通过**，所以路线是**手机留 RN 不动 + 桌面加 Tauri 壳**
  （Rust 只当壳、不写业务；3~10MB，用户已熟这套工具链 —— 他的 `ccg-gateway` 就是）。
  节奏建议：手机双端先做完整 → 桌面按需（可先做纯读版，不需要相机/录音/钥匙串）→ Linux 最后。
  **别一次上六端。** Apple 这道门两条路都躲不开：**iOS 与 macOS 构建都要 macOS 机器**。
- **⚠️ 桌面「两条路」的口径（2026-09-21 用户抓到矛盾后更正，务必按新口径说）**：
  六端表格里「RN+Expo → 桌面 ⚠️/❌」说的是 **RN 官方桌面支持**（`react-native-windows` / `-macos`：
  无 Linux、版本追不上我们的 RN 0.86.3）；而上面建议的 Tauri 方案**压根不用它**，
  用的是 **react-native-web + Expo 的 web 目标**。两者不矛盾，但**「再加一层壳就行」把工作说小了**：
  core 零改动（真）／界面**骨架能搬、排版要重做**（竖屏→桌面是第二套设计）／
  **平台层照样重写**（db 换 sqlite-wasm 或走 Node 侧；**`Alert` 28 处必须重写**，RNW 的
  `Alert.alert()` 是空函数、静默失败；安全存储/文件/分享/相机/录音全要写桌面实现）。
- **假设性提问的答案：若不考虑重写成本，最佳是 Flutter**（2026-09-21 用户问「最佳技术栈是什么」）。
  证据与风险见 `.workbuddy/memory/2026-09-21.md`「技术栈选型」一节。要点：
  ① `sqlite3_flutter_libs` **默认带 FTS5**、覆盖五平台 ⇒ 我们的 FTS5 可平移；
  ② 体积反而更好（现在 RN 包 53MB → Flutter 手机 12~25MB / 桌面 30~80MB）；
  ③ **鸿蒙：Flutter-OH 远强于 RNOH**（5 条版本线、262 个已适配库、支持鸿蒙 PC、出 `.hap`）；
  ④ 若「体积」第一优先 ⇒ **Tauri 2**（3~10MB）但三套 WebView 渲染不一致、移动端年轻。
  **右上角「又小又一致」目前没人做到。实际建议仍是「现在别换」。**
- **🚩 时机判断已更正（2026-09-21，比上面这条更重要）**：我此前说「最佳换栈时机 = UI 重构做完、
  iOS 要开工那一刻」—— **这句是错的，会害用户把界面写两遍**。真相是：**「UI 重构」本身就是那个
  不可逆分叉点**，换栈必须与它同时决定、不能串行。A 现在换 → 界面 1 遍 + core 译 1 遍；
  B 继续 RN → 界面 1 遍 + core 动 0 遍；**C 先重构再换 → 界面 2 遍（最差，别再提这个方案）**。
  好消息：**用户还没动手 UI 重构**，正处在可无痛选 A / B 的窗口。
- **Flutter 在 2026-09 变得比此前更硬（新证据，推翻我部分旧口径）**：
  ① **Canonical 于 Google I/O 2026 正式接管 Flutter 桌面**（三端 lead maintainer，
     Ubuntu App Center / Firmware Updater 都是 Flutter 写的）—— 结构性信号，不是社区打补丁；
  ② **Flutter 3.44（2026-06）**：多窗口支持落地、Windows 走**真 Win32**（可上 Fluent 质感）、
     跨平台 popup/tooltip/dialog 原语；
  ③ **Material / Cupertino 正从 core SDK 抽成独立包** ⇒ **框架升级不再连带 UI 破坏性变更**；
  ④ **`camera_desktop` 已到 1.2.1**（我上轮引的 0.1 是另一个包，**那次说错了**）：
     Linux GStreamer+V4L2 / macOS AVFoundation / Windows Media Foundation，枚举·预览·拍照·录像全有
     ⇒ **桌面相机缺口基本已补上**；
  ⑤ `sqflite` / `image_picker` 已有**官方桌面支持**，`file_picker`/`file_selector` 补文件选择；
  ⑥ 体积：engine 固定成本 4~8MB ⇒ 桌面包 30~80MB，**比 Tauri（3~10MB）差一个档**
     —— 而这正是用户在意的「打包体积」那一项。
- **重写估算的基准数字（做任何移植估算都用这组，别拍脑袋）**：core 源码 **5429 行 / 42 文件** +
  core 测试 **3773 行 / 22 文件** + 界面 **4692 行 / 27 文件** ⇒ **合计 13,894 行**；
  平台层 + 采集层 **1734 行**；迁移面 26 个依赖，其中 **17 个 `expo-*` 模块**要逐个找替代。
  **可复用两样**：SQL 语句与 prompt 模板**语言无关**（可逐字搬）；**181 个用例可近 1:1 译成
  Dart 测试当验收网**。
- **Tauri 专项核查（2026-09-21，用户拿自己的 `ccg-gateway` 10MB 当证据后核实）**：
  ① **他的网关我拆过**：Tauri 2 · **33,748 行 Rust** · Vue3+Element Plus · sqlx/axum/tokio/reqwest ·
  **纯桌面**（capabilities 用 `desktop-schema.json`，CI 只出 Win exe / macOS dmg / Linux AppImage）·
  **无 FTS5**。10MB 里有一部分是 `strip=true, lto=true, codegen-units=1, panic="abort"` 的功劳。
  本机另有 `cc-switch`（第三方开源，Tauri 2 · 63,141 行 Rust · React），可当参照。
  ② **那 10MB 与我们不重叠**：它是「服务器形状」（HTTP 代理 + 协议翻译 + sqlx），
  findR 是「设备形状」（相机 / 录音 / 压缩 / 钥匙串 / FTS5）。**别拿它当迁移论据。**
  ③ **Tauri 移动端三个已核实缺口，全落在关键路径**：相机只有**官方插件且仅 iOS/Android**（桌面无）；
  录音**无官方插件**，只有第三方 `tauri-plugin-audio-recorder` 0.1（手机出 M4A，格式对得上但版本太新）；
  **安全存储官方无解** —— Tauri 维护者 FabianLars 明说 stronghold「**不再推荐、v3 移除**」，
  社区 keyring **不支持 Android**。另：「Android System WebView 版本过旧」是移动端第一号已知坑。
  ④ **鸿蒙：Tauri 官方不支持，且是架构性的**（HarmonyOS NEXT 无 Android WebView 接口、无 Rust 工具链）。
  卓易通理论上能跑 Android APK，但 Tauri 强依赖系统 WebView ⇒ 双重风险。Flutter 有原生路（见上）。
  ⑤ **关键澄清：「Tauri + Rust」不是必须的** —— 可选「薄 Rust + core 留在 TS 跑在 webview（sqlite-wasm）」，
  那样 **core 零改动**；但也就拿不到「厚 Rust 压进 10MB」的可迁移性。两条都行，**得先选**。
  ⑥ **结论**：仍**不换栈**。但 **Tauri 作为「桌面壳」是真对的选择**（桌面版不需要相机/录音/钥匙串，
  恰好是它的主场，且用户已熟）—— 比 Electron 更合适，这条可以放心推荐。

## 环境坑
- bash 里先 `export PATH="/usr/bin:/bin:$PATH"`，否则 `ls`/`find`/`head` 会 command not found
- **`git push` 超过 1 分钟毫无输出 ⇒ 凭据问题**，别干等。
  修法 `gh auth setup-git`（本机 system 级是 `credential.helper=helper-selector`，非交互环境拿不到凭据）。
  **2026-09-19 已配好。**
- **同一文件的多个 Edit 不要并行发**，会丢写 —— **非重叠的改动也会丢**（2026-09-19 踩了三次，
  最后一次是类注释被同批次的代码改动覆盖）。**同文件一律串行，改完 grep 核对。**
- 多行提交信息用 `git commit -F <文件>`，别用 `-m` 传多行
- **🧪 沙箱里建不了 `refs/remotes/`**（2026-09-21 实测，别重复排查）：`git fetch origin` 会报
  `new branch main -> origin/main`、`FETCH_HEAD` 也确实写了，但 `.git/refs/remotes/origin/main`
  **就是不落盘**；`git update-ref` 返回 0 也无效，手动 `mkdir` 出来的目录**会被回滚**。
  ⇒ `git status` 永远显示 `[gone]`。**要修就在用户自己的终端跑一次 `git fetch origin`。**
  **但 `refs/heads` 与 `refs/tags` 都能正常写入**（已用临时 tag 实测）⇒
  **出包链路（打 tag → push → CI）完全不受影响**，可以放心。
- `adb` 不在 PATH：`C:\Users\mos\AppData\Local\Android\platform-tools\adb.exe`
- **自检屏最后一项「crypto.randomUUID 不可用（已走兜底）」是预期偏差，别再排查** ——
  那项测 `globalThis.crypto`，而它**在 App 里从没被赋过值**。卡片 id 其实走 `expo-crypto` 真 UUID
  （`submit.ts` 的 `newCardId()`，不经 `makeId()`）；**位置节点 / 分类 / 位置的 id 走兜底**
  （`idGen` 在 mobile 里从未被注入，`buildAdvanceDeps` 无此字段），熵 ≈41bit + 毫秒时间戳，无影响。
  **别为它改代码**；旧文档「已注入 idGen」的表述已作废（2026-09-20 修正）。
