# findR 项目长期记忆

> 🚩 **方向：RN (Expo) → Flutter**（用户 2026-09-21 拍板）。
> **新会话第一份必读：仓库根 `Flutter迁移交接.md`** —— 迁移唯一权威，9 节
> （§0 顺序+快照 / §1 路线 / §2 为何换 / §3 工作量 / §4 五决策 / §5 资产 / §6 进度 / §7 环境 / §8 铁律 / §9 用户画像）。
> `开发交接.md` 是 RN 历史：**铁律与用户口径仍有效**，但「当前进度 / 下一步 / 未验证清单 / 真机端到端」四节已作废。
> **本文件只放「每次会话都要知道且不随版本变」的 + 指针**；易变细节在交接文档，别在此重复维护。

## 一、进度（权威在交接 §0.1 / §6.2）
- core 已译完：`db/` `search/` `parse/`+`prompts/` `providers/`+`settings`+`util/` `pipeline/`+`cards/`+`media/`。
  **剩 `backup/`（996 行）= core 最后一块**，之后才是 UI（**按新设计写，别照抄 RN 界面**）。
- 每轮必跑的验收网：`dart test`（现 **272 通过**）· `dart analyze`（现 No issues found）·
  RN 侧 `pnpm check`（现 **181 passed | 2 skipped**，基线不许破）。
- ⬜ **命门第 2 层（真机验「打进 APK 那份 SQLite」也带 FTS5）未做**，且卡在「**CI 的 flutter job 还没加**」；
  第 1 层（本地）已通过 —— **别拿第 1 层冒充通过**（押注在 `test/fts5_trigram_test.dart`）。
- `findr_core` 依赖：`sqlite3 ^3.6.0`（DB）+ `http ^1.2.0` / `http_parser ^4.0.0`（联网，等价 TS 的 `fetch`）。

## 二、翻译口径（踩过才有；完整版在交接 §6.2）
- ⚙️ **写进库的时间一律走 `util/iso.dart` 的 `isoUtc()`**（JS `toISOString()` 恒 UTC `...Z`；
  Dart 对本地时间会出 `+08:00`）。**但媒体目录月份用本地时间**（给人看的文件夹）—— 两回事，别「统一」。
- ⚙️ **手写校验必须逐字复刻 zod 的 `.catch()` 边界**：挂**字段** = 只这档回退；
  挂**数组** = 混进一个坏的 ⇒ **整个数组落空**。复刻错了不报错，只会**静默少答一条**。
- ⚙️ **`util/base64.dart` / `util/utf8.dart` 逐字搬，别换成 `dart:convert`** —— 依赖两处宽容语义
  （base64 跳过非法字符；UTF-8 遇截断按 0 补齐）；**`backup/` 是它们存在的唯一理由**。
- ⚙️ **Dart 无结构化子类型** ⇒ TS 的 `{...deps, x}` / `interface X extends Y`
  一律改成**具名参数或 `withXxx()`**（先例：`P2Output.withSynonyms` · `AdvanceDeps.withHotwords`）。
- ⚙️ 其余常有坑：参数要包成列表（无变长参）· 事务必须支持嵌套（内层 SAVEPOINT）·
  `join(' OR ')` 的空格别丢 · `Future.timeout` ≠ `AbortController`（流式另套 `Stream.timeout`）。
- 📌 有意偏差（`close()` / `currentSchemaVersion` / 枚举 `wire` / `media.audioPart` 返回具体类型 /
  `makeLlmAdapter` 抛 `UnsupportedError` / `providers/transport.dart` 刻意不进 barrel）见交接 §6.2。

## 三、已拍板决策（别再重新调研）
- **技术栈 = Flutter**。**已排除**：Tauri 2 · KMP+Compose · .NET MAUI（无 Linux）· Electron（无移动端）。**别再重开。**
- **换栈唯一主因**：要「六端 + 一套界面代码」；**体积次要**（他很在意，但没赢过一致性）。
- **换栈解决不了的**：iOS 卡在 **Mac + $99/年**；鸿蒙 Flutter-OH 是社区/华为线。
- 🔒 五决策：① 同仓 `apps/flutter/`（RN 保留只读对照）；② `packages/findr_core/` 纯 Dart 独立包；
  ③ DB **只依赖 `package:sqlite3` 3.x**（⚠️ **`sqlite3_flutter_libs` 已废弃** `0.6.0+eol`，老教程还在写它；
  3.x 用 Dart build hooks 自带预编译 SQLite、**默认含 FTS5**、全平台同一套产物 ⇒ app 端无 native 依赖）；
  ④ **不引 drift**（要逐字搬现成 SQL）；⑤ **Riverpod**。**`zod` 在 Dart 无等价物** ⇒ 手写校验。
- **Linux 排最后**；**鸿蒙靠卓易通装安卓包、不为它做任何改动**。
- RN 期两条仍有效：① APK 瘦身（expo-camera 默认打包 ML Kit）—— 用户明确**「先不改」**，别自作主张；
  ② 备份**明文不加密**（见第五节）。

## 四、角色与姿态
- 用户是**真实使用者**（真机天天用），反馈常带截图、**多数时候是对的** ⇒ **先相信他，再读代码**。
- **他不懂技术**（原话「我不是太懂技术」）⇒ 通俗、打比方，别堆术语；他会追问到明白为止，别嫌烦。
- **决策果断**，拍板后不喜反复；会**打断**你改主意 —— 顺着新的来。
- 他说「**继续做直到完成，不要等我提醒**」时**别每步停下来等确认**。

## 五、发布与备份口径
- **发布**：继续用**测试版**（release 仍签 debug 证书，可覆盖安装、数据保留）；
  **功能全做完 + 重构一版 UI** 之后才正式发，**换签名放那一步**。⇒ 对用户一律说「**覆盖安装、别卸载**」。
- **`.findrpack`** = `magic "FINDR"(5B) + 版本 u16(=1) + 标准 ZIP`，**明文不加密**。
  加密回归时提 `FORMAT_VERSION` 到 2 并按版本分派；**在那之前别动那 7 字节头、别提前加回加密骨架**（`CryptoPort` 已删）。
  两条底线：① 界面必须明说不加密（红条 + 导出前确认框）；② `settings_public` 白名单是机密性的唯一屏障。
  回归路径见 `开发交接.md`「加密怎么加回来」一节。

## 六、权威文档
- `Flutter迁移交接.md`（迁移唯一权威）· `需求.md`（产品规格最高权威）· `技术设计.md` · `场景分析.md` ·
  `prompt设计.md` · `测试计划.md` · `开发交接.md` —— **口径互相牵连，改字段或改行为必须 grep 全捞**。
- `packages/core/src/` = **要翻译的规格说明书**；`packages/core/test/*.test.ts` = **验收网**（逐条译成 Dart）。
- 出网口径：**App 只发两种请求**（送内容给模型 / 送音频转写），地址都是用户自填 `baseUrl`。
  **没有服务器 / 账号 / 登录 / 云同步 ⇒ 迁移时别引入任何后端。**
- 给用户看的三份（`findr-功能全景 / 场景手册 / 测试清单.md`）描述的是 **RN 版**行为，
  产品行为不变故大体成立，但**界面与操作路径要按 Flutter 版逐条重校**。

## 七、流程约定（RN 期；Flutter 期另行替换）
1. 开工先 `pnpm check`；改完跑 `pnpm check` + `dart test` + `dart analyze`（三条都要绿）
2. 出包前冒烟：`npx expo export ... --output-dir ../../.workbuddy/tmp/dist-smokeN`（**别落在 `apps/mobile` 下**）
3. 出包链路：提交 → push main → `git tag apk-m1-fixN` → push tag → CI `android` 约 20 分钟
4. 取包：`gh release download dev-latest --pattern '*.apk'` → 校验结构 + sha256 → 复制到桌面
5. **push / 打 tag 前必须先经用户确认**

## 八、铁律
👉 **完整十二条见交接 §8**（与 `开发交接.md` 第 0 节同源，**改一处必须同步另一处**）。最常踩：
① 文档改一处要 grep 全捞；② **同一文件的多个 Edit 不要并行发**（会丢写），串行 + 改完 grep；
③ **动数据库先写测试押着再上真机**；**功能退役优先「保留列、只摘读写两侧」，不动 schema**。
诊断反射：「看着正常但点不动 / 看不到」⇒ 先想**层叠遮挡**；「划不动」⇒ 先看**滚动容器**。

## 九、环境坑
- bash 先 `export PATH="/usr/bin:/bin:$PATH"`；**Flutter/Dart 不在 PATH** ⇒ 沙箱里加
  `export PATH="/d/my-software/scoop/apps/flutter/current/bin:$PATH"`
- ⚠️⚠️ 沙箱跑 `pub get` / `dart test` / `flutter analyze` **必须**先
  `PUB_CACHE='D:\my-develop\project\other\findR\.workbuddy\tmp\pub-cache'`，
  否则**整条命令被 SIGTERM、连输出都没有**（极易误判成命令写错）；**用户自己终端不需要**。
- `flutter create` 在沙箱里最后一步（pub get）会断，但**产物完整** ⇒ 补跑一次带 PUB_CACHE 的 `flutter pub get`。
- 沙箱拉黑 `reg.exe` / `wmic.exe` ⇒ `flutter doctor` 三项报 `check crashed`，**那是沙箱不是环境问题**。
- 沙箱建不了 `.git/refs/remotes/` ⇒ `git status` 恒显示 `[gone]`（**不影响 push / 打 tag**）；
  **核对远端用 `git ls-remote origin main`**。`git push` 超 1 分钟无输出 ⇒ 凭据问题（`gh auth setup-git`）。
- 多行提交信息用 `git commit -F <文件>`，别用 `-m`。
- 🚫 **别用 `flutter upgrade` 升级 scoop 装的 SDK**（目录带 `.git`，与 scoop 账本不一致）；本机已 `scoop hold` 冻 3.47.5。
  **CI 里版本号也要写死**，别写 `channel: stable`。
- `adb` 不在 PATH：`C:\Users\mos\AppData\Local\Android\platform-tools\adb.exe`
- RN 版自检屏「crypto.randomUUID 不可用（已走兜底）」是**预期偏差，别再排查**。
- `.workbuddy/tools/probe-hbc-strings.py` 是 **RN 专有，迁移后作废**，别再找；
  但 APK 拆解手法（`zipfile` 按 `compress_size` 聚合）仍有用。

## 十、历史与证据
- 迁移决策的完整调研 ⇒ `.workbuddy/memory/2026-09-21.md`；按日日志（append-only）：`2026-09-18..22.md`。
- 维护：**超 30 天的日志按主题蒸馏进本文件后删除**。
