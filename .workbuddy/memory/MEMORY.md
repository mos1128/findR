# findR 项目长期记忆

> 🚩 **方向：从 RN (Expo) 迁移到 Flutter**（用户 2026-09-21 拍板）。
> **新会话第一份必读：仓库根 `Flutter迁移交接.md`** —— 迁移唯一权威，**9 节**
> （§0 顺序+快照 / §1 路线 / §2 为何换 / §3 工作量 / §4 五决策 / §5 资产 / §6 进度 / §7 环境 / §8 铁律 / §9 用户画像）。
> `开发交接.md` 是 RN 历史，**铁律与用户口径仍有效**，但「当前进度/下一步/未验证清单/真机端到端」四节已作废。
> 本文件只放「每次会话都要知道、且不随版本变」的 + 指针；**易变细节在交接文档里，别在此重复维护**。

## 一、进度快照（2026-09-22）
- 🔄 **core 翻译中：约 3,670 / 5,429 行 ≈ 68%**（全局 13,894 ≈ 26%）。
  ✅ 骨架 + **`db/` 整层** + **`search/` 整层** + **`parse/` 整层** + **`prompts/` 整层**
  + **`providers/` 整层**（含真正联网的 openai_compat / anthropic / capabilities / sse /
  samples / factory / media）+ **`settings.dart`** + **`util/base64` · `util/utf8`**。
- ⬜ **下一步 = `pipeline/`**（合 **616 行**）：`capture`(326) · `edit`(156) · `queue`(119) · `ingest`(15)；
  顺带把 `cards/`(77) + `media/`(35) 译掉（capture 依赖它们）。
  验收网 = `pipeline.test.ts` **31 个用例** + `samples.test.ts` 6 个
  （**20 条手工样本集在 `packages/core/test/fixtures/`，要一并搬**）。
  再往后 → `backup/`(996) → **最后才 UI（按新设计写）**。明细见交接 §6.2。
- ✅ **命门第 1 层（本地）通过**：SQLite 3.53.4 / `[ENABLE_FTS5]` / trigram 下 `MATCH '圆珠笔'` 命中 1 条；
  2 字 1 字**返回空且不抛异常** ⇒ TS 侧「≥3 字 MATCH、更短 LIKE 降级」照搬即可。
  押注 `packages/findr_core/test/fts5_trigram_test.dart`。
- ⬜ **命门第 2 层（真机）未做** —— 验「打进 APK 那份 SQLite」也带 FTS5，**别拿第 1 层冒充通过**。
- ⬜ **CI 的 flutter job 未加** —— 出包链路缺这一环，命门第 2 层卡在它上面。
- 验收网（每轮实测）：`dart test` **226 通过**、`dart analyze` **No issues found**、
  **RN 侧 `pnpm check` 仍 181 passed | 2 skipped**（基线未破）。
- ✅ 骨架：`apps/flutter/`（**`com.findr.app.dev`** —— 与 RN 版并排共存、碰不到真实数据）
  + `packages/findr_core/`（纯 Dart）；`pnpm-workspace.yaml` 已排除这两个 Dart 目录。
- ✅ RN 版终态已 push `ceaa4f4`（参照实现 + 回滚路）。
- ✅ **原那笔债已还**：`P2Output` 等的手写校验已随 `parse/schema.dart` 落地（见第二节）。
- 📦 **`findr_core` 依赖两条线**：`sqlite3 ^3.6.0`（DB）+ **`http ^1.2.0` / `http_parser ^4.0.0`**
  （联网，对应 TS 的 `fetch`；选它而非 `dart:io`：`MultipartRequest` 直接给 multipart 编码、
  `StreamedResponse` 正好承接 SSE、**注入 `http.Client` 等价于 TS 注入 `fetchFn`**）。

## 二、翻译口径（踩过才有）
- ⚙️ **写进库的时间一律走 `util/iso.dart` 的 `isoUtc()`** —— JS `toISOString()` 恒为 UTC 的 `...Z`；
  Dart `toIso8601String()` 对本地时间会输出 `+08:00`。这些串同时是**列值/排序键/备份包字段**，变形状全错。
- ⚙️ **参数包成列表**（Dart 无变长参数）；驱动接口保持 TS 的 `exec`/`prepare`/`transaction` 形状才好抄。
- ⚙️ **事务必须支持嵌套**（内层 SAVEPOINT）—— taxonomy/repository 里存在事务套事务。
- ⚙️ `join(' OR ')` 的空格别丢（丢了测试会精确抓到）。
- ⚙️ **手写校验必须逐字复刻 zod 的 `.catch()` 边界**（`parse/schema.dart`）：挂在**字段**上 =
  「只这一档回退」；挂在**数组**上 = 「数组里混进一个坏的 ⇒ **整个数组落空**」。
  **复刻错了不报错，只会静默地少答一条** ⇒ `parse_test.dart` 专门钉这个边界。
- ⚙️ **`util/base64.dart` / `util/utf8.dart` 是逐字搬的，别换成 `dart:convert`** ——
  有两处语义我们**依赖**：① base64 **解码对非法字符宽容**（跳过、返回已解出的部分），
  `base64Decode` 直接抛 `FormatException`；② UTF-8 **解码遇截断序列按 0 补齐**
  （JS `undefined & 0x3f === 0`），Dart 不特判抛 `RangeError`。两条都有对照组断言钉着。
- ⚙️ **`Future.timeout` ≠ TS 的 `AbortController`**：只是「不再等」，不掐 socket。
  流式那条路另外套了 `Stream.timeout`（**到点真 cancel 订阅**）。见 `providers/transport.dart`。
- ⚙️ `providers/transport.dart` 是**新增的内部文件**（URL 归一化 / 超时 / 读体 / `asMap`+`asInt`），
  TS 里这些重复了两三遍；**刻意不从 barrel 导出**。
- 其余有意偏差（`close()` / `parseJsonArray` / `currentSchemaVersion` / 枚举 `wire` /
  `media.audioPart` 返回具体类型 / `makeLlmAdapter` 抛 `UnsupportedError`）见交接 §6.2。

## 三、已拍板决策（别再重新调研）
- **技术栈 = Flutter**（理由见交接 §2）。**已排除**：Tauri 2（三套 WebView 不一致 + 移动端相机/录音/安全存储缺口）·
  KMP + Compose · .NET MAUI（无 Linux）· Electron（无移动端、100~300MB）。**别再重开这个话题。**
- **换栈唯一主因**：用户要「六端 + 一套界面代码」；**体积次要**（他很在意，但没赢过一致性）。
- **换栈解决不了的**：iOS 卡点在 **Mac + $99/年**（Apple 规则）；鸿蒙 Flutter-OH 是社区/华为线。
- 🔒 **五个开工决策（2026-09-21 全定案）**：① 同仓 `apps/flutter/`（旧 RN 保留只读对照）；
  ② `packages/findr_core/` 独立纯 Dart 包（`dart test` 直接跑；V2/V3 复用）；
  ③ 数据库**只依赖 `package:sqlite3` 3.x**（⚠️ **`sqlite3_flutter_libs` 已废弃** `0.6.0+eol`，
  README 明说「什么都不做」，老教程还在写它）—— 它用 Dart build hooks 自带预编译 SQLite，
  **默认含 `SQLITE_ENABLE_FTS5`**、全平台同一套产物 ⇒ **app 端不加任何 native 库依赖**；
  ④ **不引 drift**（要逐字搬现成 SQL）；⑤ **Riverpod**；core 必须 Dart 重写，按块从底层往上。
  **`zod` 在 Dart 无等价物** ⇒ 手写校验，别引重框架。
- **Linux 排最后**；**鸿蒙靠卓易通装安卓包、不为它改动**；**UI 重构直接在 Flutter 做 —— 别先照抄 RN 界面**。
- RN 期两条仍有效：① **APK 瘦身**（expo-camera 默认打包 ML Kit）—— 用户明确**「先不改」**，别自作主张；
  ② 备份**明文不加密**（见第五节）。

## 四、角色与姿态
- 用户是**真实使用者**（真机天天用），反馈常带截图、**多数时候是对的** ⇒ **先相信他，再读代码**。
- **他不懂技术**（原话「我不是太懂技术」）⇒ 通俗、打比方，别堆术语；他会追问到明白为止，别嫌烦。
- **决策果断**，拍板后不喜反复（「先不改 ML Kit」说了就不再提）；会**打断**你改主意 —— 顺着新的来。

## 五、发布与备份口径（2026-09-20 拍板）
- **发布**：继续用**测试版**（release 仍签 debug 证书，可覆盖安装、数据保留）；**所有功能做完 + 重构一版 UI**
  之后才正式发布，**换签名放那一步**。⇒ 对用户一律说「**覆盖安装、别卸载**」（Flutter 版同理）。
  唯一例外：验备份本身那一步（卸载前必须先导出、把备份存到 App 之外）。
- **备份 `.findrpack`** = `magic "FINDR"(5B) + 版本 u16(=1) + 标准 ZIP`，**明文**，无口令/无 AES/无 PBKDF2。
  加密回归时提 `FORMAT_VERSION` 到 2、按版本分派；**在那之前别动那 7 字节头、别提前加回加密骨架**
  （`CryptoPort` 已删）。两条底线：① 界面必须明说不加密（红条 + 导出前确认框）；
  ② `settings_public` 白名单是机密性的唯一屏障。回归路径写在 `开发交接.md`「加密怎么加回来」一节。

## 六、权威文档
- `Flutter迁移交接.md`（迁移唯一权威）/ `需求.md`（产品规格最高权威）/ `技术设计.md` / `场景分析.md` /
  `prompt设计.md` / `测试计划.md` / `开发交接.md` —— **六份口径互相牵连，改字段或行为必须 grep 全捞**。
- `packages/core/src/` 的 TS 实现 = **要翻译的规格说明书**。
- 桌面给用户看的三份（`findr-功能全景/场景手册/测试清单.md`）：描述的是 **RN 版**行为；
  产品行为不变故大体成立，但**涉及界面与操作路径的都要按 Flutter 版逐条重校**；出包后刷标题与包名到新 tag。
- 出网口径：**App 只发两种请求**（送内容给模型 / 送音频转写），地址都是用户自填 `baseUrl`。
  **没有服务器、没有账号、没有登录、没有云同步 ⇒ 迁移时别引入任何后端。**

## 七、流程约定（RN 期；Flutter 期另行替换）
1. 开工先 `pnpm check`；改完再跑一次（Flutter 侧加 `dart test` + `flutter analyze`）
2. 出包前本地冒烟：`cd apps/mobile && npx expo export ... --output-dir ../../.workbuddy/tmp/dist-smokeN`
   （**别落在 apps/mobile 下**，那里不在 gitignore）
3. 出包链路：提交 → push main → `git tag apk-m1-fixN` → push tag → CI `android` 约 20 分钟
4. 取包：`gh release download dev-latest --pattern '*.apk'` → 校验结构 + sha256 → 复制到桌面
5. **push / 打 tag 前必须先经用户确认**

## 八、铁律
👉 **完整十二条见 `Flutter迁移交接.md` §8**（与 `开发交接.md` 第 0 节同源，**改一处必须同步另一处**）。
最常踩的三条：① 文档改一处要 grep 全捞；② **同一文件的多个 Edit 不要并行发**（会丢写），串行 + 改完 grep；
③ **动数据库先写测试押着再上真机**；**功能退役优先「保留列、只摘读写两侧」，不动 schema**。
诊断反射：「看着正常但点不动/看不到」⇒ 先想**层叠遮挡**；「划不动」⇒ 先看**滚动容器**。

## 九、环境坑
- bash 里先 `export PATH="/usr/bin:/bin:$PATH"`
- **Flutter/Dart 不在 PATH**（scoop `env_add_path`）⇒ 沙箱里显式加
  `export PATH="/d/my-software/scoop/apps/flutter/current/bin:$PATH"`
- ⚠️⚠️ **沙箱跑 `pub get`/`dart test`/`flutter analyze` 必须先把 `PUB_CACHE` 指到工作区内**，
  否则**整条命令被 SIGTERM、连输出都没有**（极易误判成命令写错）：
  `PUB_CACHE='D:\my-develop\project\other\findR\.workbuddy\tmp\pub-cache'`。
  原因：默认缓存在用户目录，**沙箱不许写工作区外**。**用户自己终端不需要**。
- `flutter create` 在沙箱里最后一步（pub get）会断，但**产物完整**（只差 `.dart_tool/`）
  ⇒ 补跑一次带 PUB_CACHE 的 `flutter pub get`，别推倒重建。
- 沙箱拉黑 **`reg.exe`/`wmic.exe`** ⇒ `flutter doctor` 三项报 `check crashed`（Windows Version /
  Visual Studio / Connected device）。**那是沙箱，不是环境问题**（铁律 5 同类：检查器跑不起来 ≠ 能力不支持）。
- **`git push` 超 1 分钟无输出 ⇒ 凭据问题**，修法 `gh auth setup-git`（已配好）。
- **沙箱建不了 `.git/refs/remotes/`** ⇒ `git status` 永远显示 `[gone]`；`update-ref` 返回 0 也无效，
  手动 mkdir 会被回滚。**不影响 push / 打 tag**（refs/heads、refs/tags 可写）。
  **核对远端用 `git ls-remote origin main`**；要修就在用户终端跑一次 `git fetch origin`。
- 多行提交信息用 `git commit -F <文件>`，别用 `-m`。
- 🚫 **别用 `flutter upgrade` 升级 scoop 装的 SDK**（目录带 `.git`，与 scoop 账本不一致）—— 换版本一律走 scoop；
  本机已 `scoop hold flutter` 冻 3.47.5（见交接 §7.1.1）。
- `adb` 不在 PATH：`C:\Users\mos\AppData\Local\Android\platform-tools\adb.exe`
- RN 版自检屏最后一项「crypto.randomUUID 不可用（已走兜底）」是**预期偏差，别再排查**（测的 `globalThis.crypto`
  在 App 里从没赋值；卡片 id 走 expo-crypto 真 UUID）。**别为它改代码。**
- `.workbuddy/tools/probe-hbc-strings.py`（解 Hermes 字节码）**RN 专有，迁移后作废**，别再找；
  但 **APK 拆解手法**（`zipfile` 按 `compress_size` 聚合）仍有用。

## 十、历史与证据在哪
- **迁移决策的完整调研**（Tauri/KMP 逐项核查、Canonical 2026 接管 Flutter 桌面、3.44 多窗口与真 Win32、
  体积对比、桌面两条路口径更正）⇒ `.workbuddy/memory/2026-09-21.md`
- 按日日志（append-only）：`2026-09-18/19/20/21.md`
- 维护：**超 30 天的日志按主题蒸馏进本文件后删除**。
