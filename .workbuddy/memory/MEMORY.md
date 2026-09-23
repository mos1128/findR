# findR 长期记忆（索引，细节一律在交接文档，别在此重复）

> 🚩 **RN (Expo) → Flutter**（2026-09-21 拍板）。**新会话第一份必读 `Flutter迁移交接.md`** = 唯一权威。

## 一、进度与下一步
- 🚩 **用户 2026-09-22 澄清：一期只做安卓**（V2/V3/Linux 全算后续）。**一期的准确定义 = `技术设计.md`
  里程碑表的 M1 录入 + M2 检索 + M3 管理 + M4 备份**。剩余清单见交接 **§0.2**，别拿「六端」答一期进度。
- ✅ core 译完 · 界面按新设计写完（`flutter test` **83**）；`需求.md` §十一 MVP 8 条已核实齐。
- ✅ **命门三层全过**：真机自检两组全绿 ⇒ 随 APK 发出的那份 SQLite 确实带 FTS5 + trigram；媒体链路真机也过了。
- ✅ CI 通（**版本写死 3.47.5**）：出包发 `flutter-dev-latest`，每次都对**产物本身**断言 fts5/trigram。
  **本机没 Android SDK ⇒ 出包只能走 CI。**
- ✅ **8 个验收指标已实测完（2026-09-22，我跑的）**：除 L1 延迟（中位数 3.47s / P95 14.7s
  vs ≤3s，**不阻塞**）外全部达标。见 `测试计划.md` **§四.1**。
- ⬜ **下一步 = 真机走 `测试计划.md` §三.1 最小验收 7 条**（进行中；① 就撞出 INTERNET 坑，已修）。
  然后 UI 重构一版 → 换正式签名（**必须先导出备份、再卸载重装**）。
- ⚠️ 答「**一期做完了吗**」：**能日常用是真的，但一期没完成** —— 功能面齐 ≠ 验收过；
  **别把「能装能用」说成「开发完成」。**
- 每轮必跑：core `analyze`+`test`（**291**）· app `analyze`+`test`（**83**）· TS `pnpm check`（**181/2**，基线不许破）。

## 二、已拍板决策（别再重新调研）
- **技术栈 = Flutter**（已排除 Tauri 2 · KMP+Compose · .NET MAUI · Electron，**别再重开**）。
  唯一主因是「六端 + 一套界面代码」；iOS 卡 Mac + $99/年，鸿蒙靠卓易通装安卓包、不为它改动。
- 五决策（§4）：同仓 `apps/flutter/`（RN 只读）· `packages/findr_core/` 纯 Dart 独立包 ·
  DB 只用 `package:sqlite3` 3.x（**`sqlite3_flutter_libs` 已废弃**）· **不引 drift** · **Riverpod**。
- **发布**：现在仍是**测试版**（release 签 debug 证书）⇒ 对用户一律说「**覆盖安装、别卸载**」。
  ⚠️ **换签名这道闸已开**（M4 备份已完成）；换签名**必须卸载重装**，顺序铁的：先导出备份存到 App 之外。
- **`.findrpack`** = `FINDR`(5B) + u16 + ZIP，**明文**；加密回归才把 `FORMAT_VERSION` 提到 2，
  **在那之前别动 7 字节头、别加回加密骨架**。底线：界面必须明说不加密。

## 三、角色与姿态
- 用户是**真实使用者**（真机天天用），反馈常带截图、**多数是对的** ⇒ **先相信他，再读代码**。
- **他不懂技术** ⇒ 通俗、打比方、别堆术语。**决策果断**，不喜反复，会**打断**你改主意。
- 他说「**继续做直到完成，不要等我提醒**」时**别每步停下等确认**（提交 / 推送 / 触发 CI 也照做）。

## 四、文档与铁律
- **六份口径互相牵连，改字段或行为必须 grep 全捞**：`需求.md`（最高权威）· `技术设计.md` · `场景分析.md` ·
  `prompt设计.md` · `测试计划.md` · `开发交接.md`。
- 出网口径：**App 只发两种请求**（送内容给模型 / 送音频转写），地址是用户自填 `baseUrl`。
  **没服务器 / 账号 / 云同步 ⇒ 别引入任何后端。**
- 🚨 **release 包的权限必须自己声明**（插件只带自己的；debug/profile 清单模板自带 INTERNET ⇒
  `flutter run` 一切正常、release 全部域名解析失败 —— 2026-09-23 真机抓到，CI 已对产物断言）。
  凡迁移来的能力要问「RN 那边权限谁带的」。
- **十二条铁律见交接 §8**（与 `开发交接.md` 第 0 节同源）。最常踩：① 文档改一处 grep 全捞；
  ② **同一文件多个 Edit 别并行发**（会丢写）；③ **动数据库先写测试押着**。
  诊断：「点不动/看不到」⇒ 层叠遮挡；「划不动」⇒ 滚动容器。

## 五、环境坑（高频；完整见交接 §7.3）
- bash 先 `export PATH="/usr/bin:/bin:$PATH"`；**Flutter/Dart 不在 PATH** ⇒ 加 `/d/my-software/scoop/apps/flutter/current/bin`。
- ⚠️⚠️ 沙箱跑 Dart/Flutter **必须先** `PUB_CACHE=<工作区>/.workbuddy/tmp/pub-cache`（否则被 SIGTERM、无输出）；
  `flutter test` **还要摘代理**（unset 那四个 + `NO_PROXY=127.0.0.1,localhost`）。
- 沙箱两处「像坏了其实不是」：拉黑 `reg.exe`/`wmic.exe` ⇒ `flutter doctor` 三项 `check crashed`；
  建不了 `.git/refs/remotes/` ⇒ `git status` 恒 `[gone]`（不影响 push，核对远端用 `git ls-remote`）。
- 🚫 **别用 `flutter upgrade` 升级 scoop 装的 SDK**；本机已 `scoop hold` 冻 3.47.5。
- 🟢 **本机有模型网关 `127.0.0.1:7788`**（Key `ccg-gateway`、模型 `claude-opus-5`）⇒
  跑 core 的 live 指标**不用向用户要配置**（别再写「需要地址 + Key」），~6 分钟。
- ⚠️ 写界面两坑：① **平台插件别放首帧关键路径 `await`**（test 宿主里永不返回，改「先返回 + `unawaited`」）；
  ② 令牌类叫 `Radii` 别叫 `Radius`（撞 `dart:ui`）。
