# findR 项目长期记忆

> 🚩 **方向：RN (Expo) → Flutter**（2026-09-21 拍板）。
> **新会话第一份必读：仓库根 `Flutter迁移交接.md`** —— 迁移唯一权威（§0 顺序+快照 / §1 路线 / §2 为何换 /
> §3 工作量 / §4 五决策 / §5 资产 / §6 进度与翻译口径 / §7 环境 / §8 铁律 / §9 用户画像）。
> `开发交接.md` 是 RN 历史：**铁律与用户口径仍有效**，但「当前进度 / 下一步 / 未验证清单 / 真机端到端」四节已作废。
> **本文件只放「每次会话都要知道且不随版本变」的 + 指针**；易变细节在交接文档，别在此重复维护。

## 一、进度（权威在交接 §0.1 / §6.2）
- ✅ **core 实质译完**：`db/` `search/` `parse/`+`prompts/` `providers/`+`settings`+`util/`
  `pipeline/`+`cards/`+`media/` `backup/` 全部译完（5,394 / 5,429；**剩的 35 行只是 TS 的 `src/index.ts` 桶文件**）。
- ⬜ **下一块 = UI**（在 `apps/flutter/`，**按新设计写，别照抄 RN 界面**）。两件前置**已办完**：
  ① ✅ **CI flutter job 已加**：`.github/workflows/flutter.yml`（`checks` 作业：push/PR 跑 core 的
  `dart analyze`+`dart test` 与 app 的 `flutter analyze`+`flutter test`；`apk` 作业：**只有 tag `fapk-*`
  或手动**才出包，会**从 APK 里抽出 SQLite 的 `.so` 断言含 `fts5`/`trigram`**，发到 `flutter-dev-latest`。
  **版本号写死 `3.47.5`，绝不写 `channel: stable`**；tag 用 `fapk-*` 免得与 RN 的 `apk-*` 撞车）；
  ② 命门**第 2 层**（真机）载体已就位，**但那一步本身还没做** —— 拿 APK 装手机看自检屏七项。
  **本机没 Android SDK ⇒ 出包只能走 CI**（这就是「先补 CI 再验第 2 层」的真实原因）。
  自检三层共用 `lib/selfcheck.dart`：第 1 层 `test/selfcheck_test.dart`（`dart test`）·
  **中间层 `apps/flutter/test/self_check_smoke_test.dart`（`flutter test`）** · 第 2 层自检屏。
  **别拿前两层冒充第 2 层**（前两层跑的都是桌面的产物）。
- ✅ **中间层已通过（2026-09-22）**：`flutter test` 下七项全绿，SQLite **3.53.4** / `ENABLE_FTS5`，
  与第 1 层同值 ⇒ 同源；`build/native_assets/` 有产物 ⇒ **`enable-native-assets` 不用管，默认就开着**。
- 每轮必跑验收网：`dart test`（**289 通过**）· `dart analyze` · `flutter analyze` · `flutter test`（**2 通过**）·
  RN 侧 `pnpm check`（**181 passed | 2 skipped**，基线不许破）。
- ✅ **备份包已实测「跨实现双向互认」**（RN 能导入 Flutter 导出的 `.findrpack`），证据见交接 §6.2。
- `findr_core` 依赖：`sqlite3 ^3.6.0`（DB）+ `http ^1.2.0` / `http_parser ^4.0.0`（等价 TS `fetch`）。

## 二、翻译口径（踩过才有；完整版在交接 §6.2）
- ⚙️ **写进库的时间一律走 `util/iso.dart` 的 `isoUtc()`**（JS `toISOString()` 恒 UTC `...Z`；
  Dart 对本地时间会出 `+08:00`）。**但媒体目录月份用本地时间**（给人看的文件夹）—— 别「统一」。
- ⚙️ **手写校验必须逐字复刻 zod 的 `.catch()` 边界**：挂**字段** = 只这档回退；
  挂**数组** = 混进一个坏的 ⇒ **整个数组落空**。复刻错了不报错，只会**静默少答一条**。
- ⚙️ **`util/base64.dart` / `util/utf8.dart` 逐字搬，别换 `dart:convert`** —— 依赖两处宽容语义
  （base64 跳非法字符；UTF-8 遇截断按 0 补齐）；**`backup/` 是它们存在的唯一理由**。
- ⚙️ **Dart 无结构化子类型** ⇒ TS 的 `{...deps, x}` / `interface X extends Y` / 可选方法 `exists?`
  一律改**具名参数、`withXxx()` 或可空函数类型 getter**（先例 `P2Output.withSynonyms` ·
  `AdvanceDeps.withHotwords` · `MediaStorePort.exists`）。`MaybePromise<T>` 用 SDK `FutureOr<T>`。
- ⚙️ **Dart `DateTime` 带 `isUtc`，JS `Date` 没有** ⇒ TS 用 `getFullYear()` / `getHours()` 这类
  **本地时间取值器**处（`media/paths.dart` 的 `monthDir`、`backup/zip.dart` 的 DOS 时间戳），
  Dart 必须先 `.toLocal()`，否则跨月那几小时文件落错文件夹。
- ⚙️ `Uint8List` 上**没有** `byteOffset` / `byteLength` ⇒ Dart 的 `TypedData` 叫 `offsetInBytes` / `lengthInBytes`。
- ⚙️ 其余常有坑：参数要包成列表（无变长参）· 事务必须支持嵌套（内层 SAVEPOINT）·
  `join(' OR ')` 空格别丢 · `Future.timeout` ≠ `AbortController`（流式另套 `Stream.timeout`）。
- 📌 有意偏差（`close()` / `currentSchemaVersion` / 枚举 `wire` / `media.audioPart` 返回具体类型 /
  `makeLlmAdapter` 抛 `UnsupportedError` / `providers/transport.dart` 不进 barrel）见交接 §6.2。

## 三、已拍板决策（别再重新调研）
- **技术栈 = Flutter**。**已排除**：Tauri 2 · KMP+Compose · .NET MAUI（无 Linux）· Electron（无移动端）。**别再重开。**
- **换栈唯一主因**：要「六端 + 一套界面代码」；**体积次要**（他很在意，但没赢过一致性）。
- **换栈解决不了的**：iOS 卡在 **Mac + $99/年**；鸿蒙 Flutter-OH 是社区/华为线。
- 🔒 五决策：① 同仓 `apps/flutter/`（RN 保留只读对照）；② `packages/findr_core/` 纯 Dart 独立包；
  ③ DB **只依赖 `package:sqlite3` 3.x**（⚠️ **`sqlite3_flutter_libs` 已废弃** `0.6.0+eol`，老教程还在写；
  3.x 用 Dart build hooks 自带预编译 SQLite、默认含 FTS5、全平台同一产物 ⇒ app 端无 native 依赖）；
  ④ **不引 drift**（要逐字搬现成 SQL）；⑤ **Riverpod**。**`zod` 在 Dart 无等价物** ⇒ 手写校验。
- **Linux 排最后**；**鸿蒙靠卓易通装安卓包、不为它做任何改动**。
- RN 期仍有效：① APK 瘦身（expo-camera 默认打包 ML Kit）—— 用户明确**「先不改」**；② 备份**明文不加密**。

## 四、角色、口径、环境
- 用户是**真实使用者**（真机天天用），反馈常带截图、**多数时候是对的** ⇒ **先相信他，再读代码**。
- **他不懂技术** ⇒ 通俗、打比方，别堆术语；他会追问到明白为止。**决策果断**，不喜反复，会**打断**你改主意。
- 他说「**继续做直到完成，不要等我提醒**」时**别每步停下来等确认**。
- **发布**：继续**测试版**（release 仍签 debug 证书，可覆盖安装、数据保留）；**功能全做完 + 重构一版 UI**
  之后才正式发，**换签名放那一步** ⇒ 对用户一律说「**覆盖安装、别卸载**」。
- **`.findrpack`** = `magic "FINDR"(5B) + 版本 u16(=1) + 标准 ZIP`，**明文不加密**。加密回归时提
  `FORMAT_VERSION` 到 2 并按版本分派；**在那之前别动 7 字节头、别加回加密骨架**（`CryptoPort` 已删）。
  两条底线：① 界面必须明说不加密（红条 + 导出前确认框）；② `settings_public` 白名单是机密性唯一屏障。
- **权威文档**：`Flutter迁移交接.md`（迁移权威）· `需求.md`（最高权威）· `技术设计.md` · `场景分析.md` ·
  `prompt设计.md` · `测试计划.md` · `开发交接.md` —— **改字段或改行为必须 grep 全捞**。
  `packages/core/src/` = **要翻译的规格说明书**；`packages/core/test/*.test.ts` = **验收网**。
- 出网口径：**App 只发两种请求**（送内容给模型 / 送音频转写），地址都是用户自填 `baseUrl`。
  **没有服务器 / 账号 / 登录 / 云同步 ⇒ 别引入任何后端。**
- 给用户看的三份（`findr-功能全景 / 场景手册 / 测试清单.md`）描述 **RN 版**行为；产品行为不变故大体成立，
  **界面与操作路径要按 Flutter 版逐条重校**。
- **铁律完整十二条见交接 §8**（与 `开发交接.md` 第 0 节同源，**改一处必须同步另一处**）。最常踩：
  ① 文档改一处要 grep 全捞；② **同一文件的多个 Edit 不要并行发**（会丢写），串行 + 改完 grep；
  ③ **动数据库先写测试押着再上真机**；**功能退役优先「保留列、只摘读写两侧」，不动 schema**。
  诊断反射：「看着正常但点不动 / 看不到」⇒ 先想**层叠遮挡**；「划不动」⇒ 先看**滚动容器**。
- 流程：改完跑 `pnpm check` + `dart test` + `dart analyze`（三条都要绿）；RN 出包链路与取包手法见交接。
  **push / 打 tag 前一般要先经用户确认**（他说「别等我提醒」时除外）。
- 环境坑：bash 先 `export PATH="/usr/bin:/bin:$PATH"`；**Flutter/Dart 不在 PATH** ⇒ 加
  `export PATH="/d/my-software/scoop/apps/flutter/current/bin:$PATH"`；
  ⚠️⚠️ 沙箱跑 `pub get`/`dart test`/`flutter analyze` **必须**先
  `PUB_CACHE='D:\my-develop\project\other\findR\.workbuddy\tmp\pub-cache'`，否则**整条命令被 SIGTERM、连输出都没有**；
  ⚠️⚠️ 沙箱跑 `flutter test` **必须先摘代理**：`unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY` +
  `NO_PROXY=127.0.0.1,localhost`，否则 Dart 的 WebSocket 把回环连接塞进代理，报
  `Unable to connect to flutter_tester process: Invalid WebSocket upgrade request`（**像 Flutter 坏了，其实是代理**）；
  ⚠️ **给 `findr_core` 加依赖后 `apps/flutter` 的锁是陈旧的** ⇒ `flutter test` 会报一大片
  `Method not found`/`Undefined name`（像 core 写错了），**补跑 `flutter pub get` 即可**；
  且 **`flutter analyze` 此时仍报「No issues found」** ⇒ 「analyze 过了」不等于依赖对。
  `flutter create` 在沙箱最后一步会断但**产物完整**；沙箱拉黑 `reg.exe`/`wmic.exe` ⇒ `flutter doctor` 三项
  `check crashed`（是沙箱不是环境）；沙箱建不了 `.git/refs/remotes/` ⇒ `git status` 恒 `[gone]`
  （**不影响 push**；核对远端用 `git ls-remote origin main`）；`git push` 超 1 分钟无输出 ⇒ 凭据问题；
  多行提交信息用 `git commit -F <文件>`。
- 🚫 **别用 `flutter upgrade` 升级 scoop 装的 SDK**（目录带 `.git`，与 scoop 账本不一致）；本机已 `scoop hold` 冻 3.47.5，
  **CI 里版本号也要写死**。`adb` 在 `C:\Users\mos\AppData\Local\Android\platform-tools\adb.exe`。
  RN 版自检屏「crypto.randomUUID 不可用（已走兜底）」是**预期偏差，别再排查**。
  `.workbuddy/tools/probe-hbc-strings.py` 是 **RN 专有，迁移后作废**；但 APK 拆解手法仍有用。

## 五、历史与证据
- 迁移决策的完整调研 ⇒ `.workbuddy/memory/2026-09-21.md`；按日日志（append-only）：`2026-09-18..22.md`。
- 维护：**超 30 天的日志按主题蒸馏进本文件后删除**。
