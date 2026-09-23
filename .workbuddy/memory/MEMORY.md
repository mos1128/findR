# findR 长期记忆（索引，细节一律在交接文档，别在此重复）

> 🚩 **RN (Expo) → Flutter**（2026-09-21 拍板）；**旧版 RN/TS 代码 2026-09-23 已整块删除**。
> **新会话第一份必读 `Flutter迁移交接.md`** = 唯一权威
> （§0.1 快照 · **§0.2 一期剩余** · §4 五决策 · §6 进度 · §7 环境 · §8 铁律 · §9 用户画像）。

## 一、进度与下一步
- 🚩 **一期只做安卓**（V2/V3/Linux 算后续）。一期 = M1 录入 + M2 检索 + M3 管理 + M4 备份。
  剩余见交接 **§0.2**，别拿「六端」答进度。
- ✅ core 译完 · 界面写完 · MVP 8 条齐 · 命门三层全过 · **真机 7 条验收全过** · **UI 重构一版（用户真机验收通过）**。
- ⬜ **一期只剩「发布收尾」**：图标/启动图（素材在 `apps/flutter/assets/branding/`，未接入）·
  换正式签名（**必须先导出备份到 App 之外、再卸载重装**）· 定版本号 · 定发版方式。
- ⚠️ 答「**一期做完了吗**」：功能/验收/UI 都过了，**只剩发布收尾** ⇒ 别说成「一期完成」。
- ✅ CI 一条流水线（`flutter.yml`，**版本写死 3.47.5**）：出包发 `flutter-dev-latest`，
  对产物断言 fts5/trigram + `INTERNET`。
- ⚠️ **用户本机已有 Android 环境**（可无线调试 + 热更新）⇒ 出包不再只能走 CI。
- 每轮必跑：core `analyze`+`test`（**296**）· app `analyze`+`test`（**90**）。
  （TS 侧 `pnpm check` 已随 TS 代码废除，别再找。）
- ⚠️ **能力退化**：算那 8 个验收指标的 live 运行器（原 TS `test/live-samples.test.ts`）随源码删除，
  **Dart 侧无替代 ⇒ 指标无法复现**（数值仍在文档）。重写方案见 `测试计划.md` §二。

## 二、已拍板决策（别再重新调研）
- **技术栈 = Flutter**（已排除 Tauri 2 · KMP+Compose · MAUI · Electron，**别再重开**）；
  iOS 卡 Mac + $99/年，鸿蒙靠卓易通装安卓包。
- 五决策（§4）：同仓 `apps/flutter/` · `packages/findr_core/` 纯 Dart 独立包 ·
  DB 只用 `package:sqlite3` 3.x（`sqlite3_flutter_libs` 已废弃）· **不引 drift** · **Riverpod**。
  （原「RN 只读保留」已改判为**整块删除**，源码留在 git 历史 `ad93100`。）
- **发布**：仍是**测试版**（release 签 debug 证书）⇒ 对用户一律说「**覆盖安装、别卸载**」。
- **`.findrpack`** = `FINDR`(5B) + u16 + ZIP，**明文**；加密回归才把 `FORMAT_VERSION` 提到 2，
  在那之前别动 7 字节头、别加回加密骨架。底线：界面必须明说不加密。
- **API Key 可随备份带走**（2026-09-23 改需求）：走 manifest 可选字段 `apiKeys`，
  **与 settings 白名单两条通道**。core **只搬不读** ⇒ 默认不带；界面开关默认开、
  确认框必须**点名 Key**（包是明文）。导入**只填本机为空的槽位**（`planKeyRestore`，有单测）。

## 三、角色与姿态
- 用户是**真实使用者**：不懂技术、决策果断、反馈多数是对的 ⇒ **先信他，再读代码**；说话通俗、打比方。
  完整画像见交接 §9。他说「**继续做直到完成，不要等我提醒**」时**别每步停下等确认**。

## 四、文档与铁律
- **改字段或行为必须 grep 全捞**（最高权威 `需求.md`；另有 技术设计 / 场景分析 / prompt设计 /
  测试计划 / 最小验收清单 / `Flutter迁移交接.md`）。
  ⚠️ `技术设计.md` 写于 RN 期，选型表与目录结构已过时（顶部有状态块）——
  但**数据模型 / DDL / 算法 / 备份格式仍有效**。
- 出网口径：App 只发两种请求（送内容给模型 / 送音频转写），地址用户自填。**别引入任何后端。**
- 🚨 **release 包的权限必须自己声明**（插件只带自己的；debug/profile 模板自带 INTERNET ⇒
  `flutter run` 正常、release 全站域名解析失败 —— 2026-09-23 真机抓到，CI 已对产物断言）。
- **铁律见交接 §8**。最常踩：① 改一处 grep 全捞；② **同一文件多个 Edit 别并行发**（会丢写）；
  ③ **动数据库先写测试押着**。诊断：「点不动」⇒ 遮挡；「划不动」⇒ 滚动容器。
- ⚠️ **指标不达标先怀疑评分器**（已踩两次：滑动测试用 drag 而非 fling；path 命中率的分母）。

## 五、环境坑（高频；完整见交接 §7.3）
- bash 先 `export PATH="/c/Windows/System32:/c/Windows:/usr/bin:/bin:$PATH"`；
  Flutter/Dart 不在 PATH ⇒ 再加 `/d/my-software/scoop/apps/flutter/current/bin`。
- ⚠️⚠️ 沙箱跑 Dart/Flutter **必须先** `PUB_CACHE=<工作区>/.workbuddy/tmp/pub-cache`（否则被 SIGTERM、无输出）。
- ⚠️ **本机出网走本地代理**（`http_proxy=http://127.0.0.1:64930`）：
  **`pub get` 绝不能摘代理** —— 摘了会「成功」却把包下坏（2026-09-23 实测 `async`/`args`/`archive`/
  `audioplayers` 四个包只剩空目录，表现为 build hooks 编译失败 `Could not find pubspec.yaml`）。
  **修法**：删掉 `$PUB_CACHE/hosted/pub.dev/<坏包>`，带代理重跑 pub get。
  `flutter test` 仍按老规矩摘代理 + `NO_PROXY=127.0.0.1,localhost`。
- ⚠️ 沙箱里**大批量 `git rm` / `git add -A` 容易被 SIGTERM 掐断**并留下 `.git/index.lock`
  ⇒ 被掐后先 `rm -f .git/index.lock` 再用 `git add -A` 补暂存；
  删目录用 **PowerShell `Remove-Item -Recurse -Force`**（`cmd /c rmdir` 在 git bash 里不生效）。
- 沙箱两处「像坏了其实不是」：`flutter doctor` 三项 crashed（reg/wmic 被拉黑）；
  `git status` 恒 `[gone]`（不影响 push，用 `git ls-remote` 核对）。
- 🚫 **别用 `flutter upgrade` 升级 scoop 装的 SDK**；本机已 `scoop hold` 冻 3.47.5。
- 🟢 **本机有模型网关 `127.0.0.1:7788`**（Key `ccg-gateway`、`claude-opus-5`）—— 但跑 live 指标
  的运行器已删（见上），网关现在主要是给你自己试模型用。
- ⚠️ 写界面两坑：① **平台插件别放首帧关键路径 `await`**（test 宿主里永不返回，改「先返回 +
  `unawaited`」）；② 令牌类叫 `Radii` 别叫 `Radius`（撞 `dart:ui`）。
