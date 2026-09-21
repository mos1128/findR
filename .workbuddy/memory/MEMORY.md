# findR 项目长期记忆

> 🚩 **当前方向：从 RN (Expo) 迁移到 Flutter**（用户 2026-09-21 拍板）。
> **新会话第一份必读：仓库根 `Flutter迁移交接.md`** —— 迁移的唯一权威（路线 / 工作量 / 未决问题 / 命门）。
> `开发交接.md` 是 RN 时代历史，**十二条铁律与用户口径仍然有效**，但它的「当前进度 / 下一步 /
> 未验证清单 / 真机端到端验证」四节**已随迁移作废**。
> 本文件只放「每次会话都要知道、且不随版本变」的东西 + 指针。

## 一、当前状态（2026-09-21 收盘）
- 迁移路线：**V1 Android → V2 Windows → V3 macOS + iOS**，一版一版出、每版能独立出包。
  **Linux 排最后**（没进这三版）；**鸿蒙靠卓易通装安卓包，不为它做任何改动**。
- **UI 重构直接在 Flutter 里做** —— 别先照抄 RN 界面（用户还没动手重构，这是换栈白拿的好处）。
- ✅ **Flutter SDK 已装好**（2026-09-21，用户执行 `scoop install flutter`）：
  **3.47.5 stable / Dart 3.13.4**，`flutter --version`、`dart --version` 实测通过。
  - ⚠️ **没有 `scoop\shims\flutter` 是对的**：清单用 `env_add_path: bin` ⇒ 把 SDK 的 `bin`
    **直接挂进用户 PATH**，不生成 shim ⇒ **必须在新开的终端里用**。
  - 解压后 **3.3GB**；`scoop\cache\` 里还留着 **1.9GB** 的 zip（可 `scoop cache rm flutter` 回收）。
  - `flutter doctor`：Flutter ✅ / Chrome ✅（⇒ `flutter run -d chrome` 可用）/ Network ✅ /
    Android toolchain ❌（cmdline-tools 缺，**预期内可延后**）。
    ⚠️ doctor 里三项「check crashed」（Windows Version / Visual Studio / Connected device）是
    **我这边沙箱把 `reg.exe`、`wmic.exe` 拉黑**造成的，**不是环境问题**；
    要真实结论得让用户在**自己的终端**跑 `flutter doctor`。（铁律 5：检查器跑不起来 ≠ 能力不支持）
- **Android SDK 仍未装** —— 可延后到 V1 要上真机时再装（出包仍走 CI）。
- 第一个技术命门：**FTS5 + trigram 分词器在 Flutter 里能不能用** —— 必须实测，不通则方案重估。
  **验两层**：① 本地纯 Dart 测试（约 30 秒，验 SQL 语法）② 真机自检屏（验 APK 里那份 SQLite）。
- ✅ **迁移前那件事已办完**：RN 版终态已于 2026-09-21 push 到远端 **`ceaa4f4`**
  （`3aead1d..ceaa4f4`，6 个提交）。参照实现与回滚路都保住了。
- 迁移工作量基线：**13,894 行**（core 5429 / core 测试 3773 / 界面 4692）。
  **可直接逐字搬**：`prompts/templates.ts` + 所有 SQL 语句。**181 个用例可近 1:1 译成 Dart 当验收网。**
- ✅ **5 个决策已于 2026-09-21 全部定案**（详见交接第 4 节）：
  - **同仓 `apps/flutter/`**（旧 RN `apps/mobile/` 保留对照、只读；同一个仓库方便比对 TS 源码）
  - **`packages/findr_core/` = 新 Dart core，独立包、纯 Dart 零 Flutter 依赖**
    ⇒ 可用 `dart test` 直接跑；V2/V3 桌面版复用同一 core
  - **依赖倒置**：`findr_core` 只依赖 `sqlite3`；`sqlite3_flutter_libs` 归 `apps/flutter`
    （它唯一职责是把**带 FTS5 的 native sqlite** 打进各平台）
  - **不引 drift**（取代此前「倾向 drift」）：我们要逐字搬现成 SQL，codegen 反而多一层翻译
  - core 必须用 Dart 重写（无成熟 Dart→TS 方案），按 7 步**从底层往上**译；状态管理 **Riverpod**
  - 注：**`zod` 在 Dart 无等价物** ⇒ 手写校验函数，别为此引入重框架
  - CI 版本号要**写死**与本地一致（别写 `channel: stable`），否则「本地过、CI 挂」最难查

## 二、已拍板的决策（别再重新调研）
- **技术栈 = Flutter**。理由与证据见 `Flutter迁移交接.md` 第 2 节 + `.workbuddy/memory/2026-09-21.md`。
  **已排除**：Tauri 2（三套 WebView 渲染不一致；相机/录音/安全存储移动端有缺口）·
  KMP + Compose · .NET MAUI（无 Linux）· Electron（无移动端、100~300MB）。**别再重开这个话题。**
- **换栈的唯一主因**：用户要「六端 + 一套界面代码」。**体积是次要**（他很在意，但没赢过一致性）。
- **换栈解决不了的两件事**：iOS 的卡点是 **Mac + $99/年**（Apple 规则，与语言无关）；
  鸿蒙的 Flutter-OH 是社区/华为线，不是官方。
- 旧的「RN + Tauri 桌面壳」路线**已随 Flutter 决定作废**（Flutter 直接覆盖桌面）。
- RN 时代两条口径仍有效：① **APK 瘦身**（`expo-camera` 默认打包 ML Kit 条码扫描）——
  用户 2026-09-21 明确**「先不改」**，别自作主张加 config plugin；② 备份**明文不加密**（见第三节）。

## 三、发布与备份口径（用户 2026-09-20 拍板）
- **发布**：现在继续用**测试版**（release 仍签 debug 证书，可覆盖安装、数据保留）；
  等**所有功能做完 + 重构一版 UI** 之后才作为正式版发布，**换签名放在那一步一起做**。
  ⇒ 对用户一律说「**覆盖安装、别卸载**」（Flutter 版同理，数据在库里）。
  唯一例外是验证备份本身那一步（需要卸载重装，且卸载前必须先导出并把备份存到 App 之外）。
- **备份 `.findrpack`** = `magic "FINDR"(5B) + 版本 u16(=1) + 标准 ZIP`，**明文**，
  无口令 / 无 AES / 无 PBKDF2。`需求.md` 里「本地**加密**导出/导入备份」的「加密」二字**暂时不成立**。
  加密回归时提 `FORMAT_VERSION` 到 2、按版本分派；**在那之前别动那 7 字节头、别提前把加密骨架加回来**
  （`CryptoPort` 已删）。两条底线：① 界面必须明说不加密（页面红条 + 导出前确认框）；
  ② `settings_public` 白名单是机密性的唯一屏障。
- 回归路径与踩坑（expo-crypto 自带原生 AES、16 字节 nonce 可行、PBKDF2 必须 `pbkdf2Async` 分片）
  写在 `开发交接.md` 的「加密怎么加回来」一节，**别重新调研**。

## 四、角色与姿态
- 用户是这个 App 的**真实使用者**（在真机上天天用）。反馈是首手的、常带截图，**多数时候是对的**
  —— 2026-09-19 那次「这儿应该配置的是正确的，但是提示错误」就完全正确，是我们的探测在冤枉他。
  **先相信他，再去读代码，别先假设他填错了。**
- **他不懂技术**（原话「我不是太懂技术」）⇒ 讲结论要通俗、要打比方，别堆术语；
  他会连续追问到弄明白为止，这是正常的，别嫌烦。
- **他决策果断**，拍板后不喜欢反复（「先不改 ML Kit」说了就不再提）；
  会**打断**你改主意 —— 顺着新的来，别强行把旧问题讲完。

## 五、权威文档（别凭记忆改）
- `Flutter迁移交接.md` — **迁移唯一权威**，新会话第一份必读
- `需求.md`（产品规格，最高权威）/ `技术设计.md` / `场景分析.md` / `prompt设计.md` /
  `测试计划.md` / `开发交接.md` — **六份口径互相牵连，改字段或改行为必须 grep 全捞**
- `packages/core/src/` 的 TS 实现 —— **就是要翻译的规格说明书**
- 桌面给用户看的三份：`findr-功能全景.md` / `findr-场景手册.md` / `findr-测试清单.md`
  —— 描述的是 **RN 版**行为。产品行为不变故大体仍成立，**凡涉及界面与操作路径的描述
  都要按 Flutter 版逐条重校**；**出包后刷标题与包名到新 tag**（老规矩）。
- 出网口径：**App 只发两种请求**（送内容给模型 / 送音频转写），地址都是用户自填的 `baseUrl`。
  **没有我们的服务器、没有账号、没有登录、没有云同步 —— 迁移时别引入任何后端。**

## 六、流程约定（RN 期有效，Flutter 期另行替换）
1. 开工先 `pnpm check` 确认基线全绿；改完跑 `pnpm check` + `pnpm --filter @findr/mobile run check`
2. 出包前本地冒烟：`cd apps/mobile && npx expo export --platform android --output-dir ../../.workbuddy/tmp/dist-smokeN`
   （输出目录**别落在 apps/mobile 下**，那里不在 gitignore 里）
3. 出包链路：提交 → push main → `git tag apk-m1-fixN` → push tag → CI `android` 约 20 分钟
4. 取包：`gh release download dev-latest --pattern '*.apk'` → 校验结构 + sha256 → 复制到桌面
5. **push / 打 tag 前必须先经用户确认**（见第七节铁律）

## 七、铁律
👉 **完整十二条见 `Flutter迁移交接.md` 第 9 节**（与 `开发交接.md` 第 0 节同源，
**改一处必须同步另一处**）。**这些与语言无关，迁到 Flutter 照样成立。**
这里只重复最常踩的三条：
1. **文档改一处要 grep 全捞**（字段清单散在六份 md 里）
2. **同一文件的多个 Edit 不要并行发，会丢写**（非重叠的改动也会）—— 同文件一律串行，改完 grep 核对
3. **动数据库先写测试押着再上真机**；**功能退役优先「保留列、只摘读写两侧」，不动 schema**
另两条诊断反射：「看着正常但点不动 / 看不到」⇒ 先想**层叠遮挡**；「划不动」⇒ 先看**滚动容器**。

## 八、环境坑
- bash 里先 `export PATH="/usr/bin:/bin:$PATH"`，否则 `ls` / `find` / `head` 会 command not found
- **`git push` 超过 1 分钟毫无输出 ⇒ 凭据问题**，别干等。
  修法 `gh auth setup-git`（本机 system 级是 `credential.helper=helper-selector`）。**2026-09-19 已配好。**
- **🧪 沙箱里建不了 `.git/refs/remotes/`**（2026-09-21 实测，别重复排查）：`git fetch origin` 报
  `new branch main -> origin/main`、`FETCH_HEAD` 也确实写了，但 `.git/refs/remotes/origin/main`
  **就是不落盘**；`git update-ref` 返回 0 也无效，手动 `mkdir` 出来的目录**会被回滚**
  ⇒ `git status` 永远显示 `[gone]`。**要修就在用户自己的终端跑一次 `git fetch origin`。**
  但 **`refs/heads` 与 `refs/tags` 都能正常写入** ⇒ **出包链路（打 tag → push → CI）完全不受影响**。
- 多行提交信息用 `git commit -F <文件>`，别用 `-m` 传多行
- `adb` 不在 PATH：`C:\Users\mos\AppData\Local\Android\platform-tools\adb.exe`
- **自检屏最后一项「crypto.randomUUID 不可用（已走兜底）」是预期偏差，别再排查** ——
  那项测 `globalThis.crypto`，而它**在 App 里从没被赋过值**。卡片 id 其实走 `expo-crypto` 真 UUID
  （`submit.ts` 的 `newCardId()`，不经 `makeId()`）；位置节点 / 分类 / 位置的 id 走兜底
  （`idGen` 在 mobile 里从未被注入），熵 ≈41bit + 毫秒时间戳，无影响。**别为它改代码**；
  旧文档「已注入 idGen」的表述已作废（2026-09-20 修正）。
- 工具 `.workbuddy/tools/probe-hbc-strings.py`（解 Hermes 字节码字符串表）是 **RN 专有，迁移后作废**，
  别再找它；但 **APK 拆解手法**（Python `zipfile` 按 `compress_size` 聚合）**仍然有用**。

## 九、历史与证据在哪
- **迁移决策的完整调研**（Tauri / KMP 逐项核查、Canonical 2026 接管 Flutter 桌面、
  Flutter 3.44 多窗口与真 Win32、体积对比、桌面两条路口径更正、重写估算基准）
  ⇒ `.workbuddy/memory/2026-09-21.md`
- 按日工作日志（append-only，不删）：`2026-09-18.md` / `2026-09-19.md` / `2026-09-20.md` / `2026-09-21.md`
- 维护：**超过 30 天的日志按主题蒸馏进本文件后删除**。
