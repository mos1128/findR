# findR 长期记忆（索引，细节一律在交接文档，别在此重复）

> 🚩 **RN (Expo) → Flutter**（2026-09-21 拍板）。**新会话第一份必读 `Flutter迁移交接.md`** = 唯一权威
> （§0 快照 · §4 五决策 · §6 进度 · §7 环境 · §8 铁律 · §9 用户画像）。`开发交接.md` 是 RN 历史。

## 一、进度与下一步
- ✅ core 实质译完 · ✅ `platform/` 七模块 · ✅ **界面按新设计写完、没照抄 RN**（`flutter test` 8 → **83**）。
  **`需求.md` §十一 的 MVP 8 条已逐条核实齐。**
- ✅ **命门三层全过（2026-09-22）**：真机自检两组全绿 ⇒ **随 APK 发出去的那份 SQLite 确实带
  FTS5 + trigram**。媒体链路真机也过了（竖拍照片存下来是正的）。
- ✅ CI 通（**版本写死 3.47.5**）：出包发 `flutter-dev-latest`（**22.2MB**），每次都对**产物本身**
  断言 fts5/trigram。**本机没 Android SDK ⇒ 出包只能走 CI。**
- ⬜ **下一步 = 真机把 `测试计划.md` §三 那 16 步走完** —— 至今**只走了第 1 步**（自检），
  另加竖拍方向、相册滑动。**然后**才是 UI 重构一版 / 换正式签名 / V2 Windows。
- ⚠️ 答「**开发完成了吗**」的**正确口径**：**Android 能日常用是真的，但远没到「完成」** ——
  功能面齐 ≠ 验收过 ≠ 后面两版做完。**别把「能装能用」说成「开发完成」。**
- 每轮必跑：core `dart analyze`+`dart test`（**291**）· app `flutter analyze`+`flutter test`（**83**）·
  RN `pnpm check`（**181/2**，基线不许破）。

## 二、已拍板决策（别再重新调研）
- **技术栈 = Flutter**，已排除 Tauri 2 · KMP+Compose · .NET MAUI · Electron，**别再重开**。
  **唯一主因**：要「六端 + 一套界面代码」。**换栈解决不了**：iOS 卡 **Mac + $99/年**；鸿蒙是社区/华为线。
- 五决策（§4）：同仓 `apps/flutter/`（RN 只读）· `packages/findr_core/` 纯 Dart 独立包 ·
  DB 只用 `package:sqlite3` 3.x（**`sqlite3_flutter_libs` 已废弃**）· **不引 drift** · **Riverpod**。
  **Linux 排最后**；鸿蒙靠卓易通装安卓包、不为它做任何改动。
- **发布**：继续**测试版**（release 签 debug 证书）⇒ 对用户一律说「**覆盖安装、别卸载**」；
  功能全做完 + 重构一版 UI 后才正式发，**换签名放那一步**。
- **`.findrpack`** = `FINDR`(5B) + u16 + ZIP，**明文**；加密回归才把 `FORMAT_VERSION` 提到 2，
  **在那之前别动 7 字节头、别加回加密骨架**。底线：界面必须明说不加密。
- RN 期仍有效：APK 瘦身（ML Kit）明确**「先不改」**。

## 三、角色与姿态
- 用户是**真实使用者**（真机天天用），反馈常带截图、**多数是对的** ⇒ **先相信他，再读代码**。
- **他不懂技术** ⇒ 通俗、打比方、别堆术语。**决策果断**，不喜反复，会**打断**你改主意。
- 他说「**继续做直到完成，不要等我提醒**」时**别每步停下等确认**（提交 / 推送 / 触发 CI 也照做）。

## 四、文档与铁律
- **六份口径互相牵连，改字段或行为必须 grep 全捞**：`需求.md`（最高权威）· `技术设计.md` · `场景分析.md` ·
  `prompt设计.md` · `测试计划.md` · `开发交接.md`。
- 出网口径：**App 只发两种请求**（送内容给模型 / 送音频转写），地址是用户自填 `baseUrl`。
  **没服务器 / 账号 / 登录 / 云同步 ⇒ 别引入任何后端。**
- **十二条铁律见交接 §8**（与 `开发交接.md` 第 0 节同源，**改一处必须同步另一处**）。最常踩：
  ① 文档改一处 grep 全捞；② **同一文件多个 Edit 别并行发**（会丢写）；③ **动数据库先写测试押着**；
  ④ **自检断言不能假设库是空的**。诊断反射：「点不动 / 看不到」⇒ 想**层叠遮挡**；「划不动」⇒ 看**滚动容器**。

## 五、环境坑（高频；完整见交接 §7.3）
- bash 先 `export PATH="/usr/bin:/bin:$PATH"`；**Flutter/Dart 不在 PATH** ⇒ 加 `/d/my-software/scoop/apps/flutter/current/bin`。
- ⚠️⚠️ 沙箱跑 Dart/Flutter **必须先** `PUB_CACHE=<工作区>/.workbuddy/tmp/pub-cache`，否则**被 SIGTERM、无输出**；
  **`flutter test` 还要摘代理**（`unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY` + `NO_PROXY=127.0.0.1,localhost`），
  否则报 `Unable to connect to flutter_tester`。
- 沙箱两处「像坏了其实不是」：拉黑 `reg.exe`/`wmic.exe` ⇒ `flutter doctor` 三项 `check crashed`；
  建不了 `.git/refs/remotes/` ⇒ `git status` 恒 `[gone]`（不影响 push，核对远端用 `git ls-remote origin main`）。
- 🚫 **别用 `flutter upgrade` 升级 scoop 装的 SDK**；本机已 `scoop hold` 冻 3.47.5。
- ⚠️ 写界面两个通用坑：① **平台插件别放首帧关键路径 `await`** —— widget test 宿主里永不返回
  （改「先返回、`unawaited` 后补」）；② **令牌类叫 `Radii` 别叫 `Radius`**（撞 `dart:ui`）。

## 六、历史
- 迁移调研 ⇒ `2026-09-21.md`；按日日志 `2026-09-18..22.md`。
