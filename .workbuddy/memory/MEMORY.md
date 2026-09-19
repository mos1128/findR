# findR 项目长期记忆

> 详细交接在仓库根 `开发交接.md`（**唯一权威**）。这里只放「每次会话都要知道、且不随版本变」的东西。

## 角色与姿态
- 用户是这个 App 的**真实使用者**（在真机上天天用）。他的反馈是首手的、常带截图，
  而且**多数时候是对的** —— 2026-09-19 那次「这儿应该配置的是正确的，但是提示错误」就完全正确，
  是我们的探测在冤枉他。**先相信他，再去读代码，别先假设他填错了。**

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

## 环境坑
- bash 里先 `export PATH="/usr/bin:/bin:$PATH"`，否则 `ls`/`find`/`head` 会 command not found
- **`git push` 超过 1 分钟毫无输出 ⇒ 凭据问题**，别干等。
  修法 `gh auth setup-git`（本机 system 级是 `credential.helper=helper-selector`，非交互环境拿不到凭据）。
  **2026-09-19 已配好。**
- **同一文件的多个 Edit 不要并行发**，会丢写 —— **非重叠的改动也会丢**（2026-09-19 踩了三次，
  最后一次是类注释被同批次的代码改动覆盖）。**同文件一律串行，改完 grep 核对。**
- 多行提交信息用 `git commit -F <文件>`，别用 `-m` 传多行
- `adb` 不在 PATH：`C:\Users\mos\AppData\Local\Android\platform-tools\adb.exe`
