# findR 项目长期记忆（索引，细节一律写进交接文档，别在此重复）

> 🚩 **RN (Expo) → Flutter**（2026-09-21 拍板）。
> **新会话第一份必读：仓库根 `Flutter迁移交接.md`** = 迁移唯一权威：
> §0 快照 / §1 路线 / §2 为何换 / §3 工作量 / §4 五决策 / §5 资产 /
> §6 进度（**6.1 命门** · 6.2 core 口径 · **6.3 应用层**）/ §7 环境 / §8 十二条铁律 / §9 用户画像。
> `开发交接.md` 是 RN 历史：**铁律与用户口径仍有效**，但「当前进度/下一步/未验证清单/真机端到端」四节已作废。

## 一、进度与下一步（权威在交接 §0.1 / §6.3）
- ✅ **core 实质译完**（5,394/5,429；剩 35 行只是 TS 的 `src/index.ts` 桶文件）。
- ✅ **应用层 `platform/` 七个模块全写完**（app_paths · db · media · device_selfcheck · secure ·
  backup · runtime）⇒ **UI 之前再无接线欠账**。
- ✅ **界面已按新设计写完、没照抄 RN**（`theme/` `ui/` `state/` `capture/`(文字) `screens/`）。
- ✅ **CI 通**：`.github/workflows/flutter.yml`（`checks` 全绿；`apk` 出包 18.2MB 并已发布
  `flutter-dev-latest`，且断言过「APK 里 `libsqlite3.so` 含 `fts5`/`trigram`」）。
- **自检三层**（共用 core 的 `selfcheck.dart`）：`dart test` · `flutter test` · **App 自检屏（真机）**。
  **别拿前两层冒充真机那层。** ⚠️ **自检入口已挪到「设置 → 维护」**（`home` 换成记忆流主页了）。
- ⬜ **下一步**：① **媒体录入**（录入坞相机/相册/长按录音 + 图片 WebP 压缩）+ **音频播放**
  （卡片详情现在只占位）；② 真机自检屏两组全绿 = 命门第 2 层过。
  **本机没 Android SDK ⇒ 出包只能走 CI。**
- 每轮必跑：core `dart analyze`+`dart test`（**291**）· app `flutter analyze`+`flutter test`（**37**）·
  RN `pnpm check`（**181 passed / 2 skipped**，基线不许破）。

## 二、已拍板决策（别再重新调研）
- **技术栈 = Flutter**。已排除 Tauri 2 · KMP+Compose · .NET MAUI（无 Linux）· Electron（无移动端）。**别再重开。**
  **唯一主因**：要「六端 + 一套界面代码」。**换栈解决不了的**：iOS 卡在 **Mac + $99/年**；鸿蒙是社区/华为线。
- 五决策（§4）：同仓 `apps/flutter/`（RN 保留只读）· `packages/findr_core/` 纯 Dart 独立包 ·
  DB **只依赖 `package:sqlite3` 3.x**（**`sqlite3_flutter_libs` 已废弃**，老教程还在写它；3.x 用 build hooks
  自带预编译 SQLite、默认含 FTS5、全平台同一产物 ⇒ app 端无 native 依赖）· **不引 drift** · **Riverpod**。
  **`zod` 无 Dart 等价物** ⇒ 手写校验。
- **Linux 排最后**；**鸿蒙靠卓易通装安卓包、不为它做任何改动**。
- RN 期仍有效：APK 瘦身（ML Kit）用户明确**「先不改」**；备份**明文不加密**。
- **发布**：继续**测试版**（release 签 debug 证书）⇒ 对用户一律说「**覆盖安装、别卸载**」；
  **功能全做完 + 重构一版 UI** 后才正式发，**换签名放那一步**。
- **`.findrpack`** = `FINDR`(5B) + u16 版本 + 标准 ZIP，**明文**；加密回归时提 `FORMAT_VERSION` 到 2，
  **在那之前别动 7 字节头、别加回加密骨架**（`CryptoPort` 已删）。两条底线：界面必须明说不加密；
  `settings_public` 白名单是机密性唯一屏障。

## 三、角色与姿态
- 用户是**真实使用者**（真机天天用），反馈常带截图、**多数时候是对的** ⇒ **先相信他，再读代码**。
- **他不懂技术** ⇒ 通俗、打比方，别堆术语；会追问到明白为止。**决策果断**，不喜反复，会**打断**你改主意。
- 他说「**继续做直到完成，不要等我提醒**」时**别每步停下来等确认**。

## 四、文档、流程、铁律
- **六份口径互相牵连，改字段或改行为必须 grep 全捞**：`需求.md`（最高权威）· `技术设计.md` ·
  `场景分析.md` · `prompt设计.md` · `测试计划.md` · `开发交接.md`。
  `packages/core/src/` = **要翻译的规格说明书**；`packages/core/test/*.test.ts` = **验收网**。
- 出网口径：**App 只发两种请求**（送内容给模型 / 送音频转写），地址是用户自填 `baseUrl`。
  **没有服务器 / 账号 / 登录 / 云同步 ⇒ 别引入任何后端。**
- **十二条铁律见交接 §8**（与 `开发交接.md` 第 0 节同源，**改一处必须同步另一处**）。最常踩：
  ① 文档改一处 grep 全捞；② **同一文件多个 Edit 别并行发**（会丢写）；③ **动数据库先写测试押着**；
  ④ **自检断言不能假设库是空的**（数「预设」而非全部）。诊断反射：「看着正常但点不动/看不到」⇒
  先想**层叠遮挡**；「划不动」⇒ 先看**滚动容器**。
- **push / 打 tag 前一般要先经用户确认**（他说「别等我提醒」时除外）。

## 五、环境坑（高频；完整见交接 §7.3）
- bash 先 `export PATH="/usr/bin:/bin:$PATH"`；**Flutter/Dart 不在 PATH** ⇒ 加
  `export PATH="/d/my-software/scoop/apps/flutter/current/bin:$PATH"`。
- ⚠️⚠️ 沙箱跑 Dart/Flutter **必须**先 `PUB_CACHE='D:\my-develop\project\other\findR\.workbuddy\tmp\pub-cache'`，
  否则**被 SIGTERM、连输出都没有**；**`flutter test` 还要摘代理**（`unset http_proxy https_proxy
  HTTP_PROXY HTTPS_PROXY` + `NO_PROXY=127.0.0.1,localhost`），否则报 `Unable to connect to flutter_tester`。
- ⚠️ 给 `findr_core` 加依赖后 `apps/flutter` 锁陈旧 ⇒ `flutter test` 报一片 `Method not found`
  （**像 core 写错**），补 `flutter pub get` 即解；那时 `flutter analyze` 仍报「No issues found」。
- ⚠️ `flutter build apk --target-platform android-arm64` 产出 **`app-release.apk`**（**无 ABI 后缀**，
  那是 `--split-per-abi` 才有）⇒ **别赌产物名，用 glob**。
- 沙箱两处「像坏了其实不是」：拉黑 `reg.exe`/`wmic.exe` ⇒ `flutter doctor` 三项 `check crashed`；
  建不了 `.git/refs/remotes/` ⇒ `git status` 恒 `[gone]`（不影响 push，核对远端用 `git ls-remote origin main`）。
- 🚫 **别用 `flutter upgrade` 升级 scoop 装的 SDK**（与 scoop 账本不一致）；本机已 `scoop hold` 冻 3.47.5，
  **CI 里版本号也写死**。
- ⚠️ **写界面时踩到的两个通用坑**（Dart/Flutter 版）：
  ① **`package_info_plus` 这类平台插件别放首帧关键路径上 `await`** —— 在 widget test 宿主里
  **永远不返回**，界面会一直转圈（改用「先返回、`unawaited` 后补」）；
  ② **令牌类叫 `Radii` 别叫 `Radius`**（与 `dart:ui` 撞名）。

## 六、历史
- 迁移决策完整调研 ⇒ `2026-09-21.md`；按日日志（append-only）`2026-09-18..22.md`。
  **超 30 天的日志按主题蒸馏进交接文档后删除。**
