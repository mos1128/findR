# Findr 开发指南

## 环境

- Flutter 3.47.5（`scoop install flutter && scoop hold flutter`）
- Dart 3.13.4
- pub workspaces：仓库根跑一次 `flutter pub get` 即可

## 架构

```
根目录/              # Flutter app（界面 + 平台接线）
├─ lib/platform/    # 设备侧：DB/媒体/备份/网络/更新
├─ lib/capture/     # 录入链路
├─ lib/ui/screens/state/theme/
└─ packages/findr_core/  # 核心逻辑（零 Flutter 依赖）
   ├─ db/           # SQLite + FTS5 trigram
   ├─ search/       # 三级检索（L1 本地/L2 答案/L3 裁决）
   ├─ providers/    # 模型适配（Anthropic/OpenAI 兼容）
   ├─ prompts/      # P1 理解/P2 查询/P3 答案/P4 裁决
   ├─ pipeline/     # 录入流水线
   └─ backup/       # .findrpack 格式
```

**铁律**：core 不 import 任何 Flutter 模块，所有 IO/网络通过接口注入。

## 命令

```bash
flutter analyze && flutter test              # 全量（app + core）
cd packages/findr_core && dart test          # 只测 core（快）
bash release.sh                              # 发版
```

**基线不许破**：core 314 条 + app 163 条，静态分析干净。

## 关键约束

### SQLite 必须带 FTS5 + trigram
整套检索建立在这上面，≥3 字走 `MATCH`，<3 字走 `LIKE`。三层验证：
1. `findr_core/test/selfcheck_test.dart`（桌面 libsqlite3）
2. `test/self_check_smoke_test.dart`（Flutter 编译的 SQLite）
3. 真机自检屏（随包发布的那份二进制）

CI 有断言：解 APK 查 `libsqlite3.so` 含 `fts5` / `trigram` 字符串。

### 权限声明（release 清单不自带）
`android/app/src/main/AndroidManifest.xml` 必须显式声明：
- `INTERNET` - 联网
- `REQUEST_INSTALL_PACKAGES` - 应用内更新拉安装界面
- `FOREGROUND_SERVICE_DATA_SYNC` - 下载保活服务

CI 有断言。`flutter run` 正常不代表 release 包正常。

### 备份格式（.findrpack）
```
magic "FINDR" (5 字节) + 版本 u16 (=1) + 标准 ZIP
```
- 设置项是整表快照：导出 `settings` 全部行，导入整表覆盖，不设白名单
- API Key 全量随包带走（`apiKeys` 字段，平台层显式传入，core 只搬不读）；导入时覆盖本机同名 Key
- 完整性全靠 ZIP 的 CRC32
- 导出/导入都走流式：导出按块写盘；导入先校验全部成员 CRC，再逐个写入（峰值内存 = 单个媒体文件）
- 导入两种模式：增量（同 id 新的胜、分类/位置重名保留本机、本地独有保留）与全量（先清空本机用户数据与媒体，再完整使用备份）
- 设置项与 API Key 两种模式都全量覆盖：备份里没有的设置键回默认值（`update_check_at` / `update_latest_tag` 这类设备本地状态除外，始终保留本机值），备份里没有的 Key 清空本机

### 数据库
- 表：`cards` / `locations` / `categories` / `aliases` / `settings` / FTS 影子表
- DDL 在 `findr_core/lib/db/schema.dart`，逐条 exec
- **SQLite 删列必须重建整张表** → 退役功能优先保留列、只摘读写
- `cards.vision_requested` 保存每条录入的图片分析选择，队列与重试优先使用它；旧卡片为 NULL 时才使用设置默认值，主动「补分析图片」仍可带图。

### 检索三级
1. **L1 本地**：P2 查询理解 → 本地 FTS5/LIKE，0 结果逐级放宽（去 category → 去 path/time → all 转 any）
2. **L2 答案组织**：top-8 片段送 P3 → 答案卡片（**永不发全库**）
3. **L3 建议裁决**：整库清单（先按相关度排序再截断 200 条）送 P4 → 必需/看情况/还缺什么

意图路由：定位题（护照在哪）走 L1+L2；推理题（出国该带啥）走 L3。

### 分享进来（ACTION_SEND）

`MainActivity` 挂着 `findr/share` 通道（Dart 侧 `lib/platform/inbound_share.dart`），
把别处分享的文字/图片预填进首页录入条。两个只在真机上才会暴露的点：

- **冷启动握手**：分享 intent 比 Dart 的 `setMethodCallHandler` 先到，Kotlin 先把它扣在
  `pendingShare` 里，等 Dart 调 `ready` 再递。少了这一步，从桌面图标冷启动的分享会被静默丢掉。
- **`content://` 当场拷**：源应用给的读权限只活在这一个 intent 的生命周期里，必须立刻把字节
  拷进 `cacheDir/share`，否则保存卡片时打开就是 `SecurityException`。

### 归档的语义

归档 = `status = 'archived'`：`listCards` 默认不返回它，检索在 SQL 里硬过滤 `active`。
所以**任何新读卡路径都要想清楚要不要归档的那些**；用户侧的出口只有
设置 → 数据与维护 → 已归档（`lib/screens/settings/archived_screen.dart`，恢复 / 彻底删除）。

### 图标与启动图
- 改图只改 `tool/gen_icons.dart` 顶部常量，然后 `dart run tool/gen_icons.dart` 一次重出全部尺寸，别手改位图
- **品牌色三处同步**：脚本 `kPaper0` / `kPaper1`、`drawable/ic_launcher_background.xml` 的渐变两端、`values/colors.xml` 的 `brand_paper`（启动屏用它，取渐变起点色）
- **内容必须落在直径 66dp 安全区内**（半径 33dp），脚本结尾会打一行自检，显示 ❌ 就是 `kContentScale` 调大了
- **单色层（主题图标）只有形状有意义**：直接取整个图形的实心轮廓（一道缺口环 + 偏心点），颜色交给系统
- 换图标覆盖安装即可，**不用卸载**（只有换签名才要）

## 发布流程

```bash
bash release.sh
# 输入新版本号（X.Y.Z，每次最后一位+1）
# 输入更新说明（手写，进 tag 注释）
# → 跑测试 → 改 pubspec.yaml → 提交 → 打 tag → 推 GitHub
# → 等 CI 出包（十几分钟）→ 本机建 Gitee 发行版 → 传附件 → 按字节数校验 → 清旧版
```

**CI 自动**（`.github/workflows/flutter.yml`）：跑测试（core 314 条 + app 163 条，约 2.5 分钟）→ 构建 APK → 发 GitHub 发布 → 镜像代码到 Gitee。**Gitee 的发行版 CI 不碰。**

**本机自动**（`release.sh` 的最后一步，`scripts/gitee-attach.sh`）：等 GitHub 出包 → 下载 → 在 Gitee 建发行版（名字与正文整份抄 GitHub 那条）→ 传附件 → HEAD 比字节数 → 删旧版（保留最新 10 个 + 清掉没有附件的空壳）。

**为什么这么分工**：runner 在境外，往 gitee.com 传 21MB 实测 1.9~20 KB/s（18~90 分钟，常以 `curl: (56)` 断在半路）；从国内宽带传只要 4.9 秒（4.7 MB/s）。代价是这期间**别关终端**。

**为什么 Gitee 的发行版要等到附件一起建**：Gitee 的 `/releases/latest` **不跳过预发布**（GitHub 会跳）。CI 先建个空壳的话，App 的「检查更新」立刻就能看到这个版本、点下载却是 404。所以规矩是 **「Gitee 上有这个版本 ⟺ 它的包能下」**：建 → 传 → 校验任一步失败，脚本会把刚建的发行版删掉；宁可国内用户晚看到，也不出现点不动的更新。

**Gitee 令牌（本机，一次性）**：最后那步要用。脚本按顺序取，取不到就把下面两条配法打出来：

1. `npm i -g @gitee/gitee-cli`，再 `gitee auth login`（令牌存 `~/.config/gitee/`，脚本用 `gitee auth token` 取）
2. `setx GITEE_TOKEN <令牌>`，重开终端生效（令牌在 Gitee → 设置 → 私人令牌，权限只勾 projects）

**换设备后要做的**：`gh auth login`（GitHub）+ 上面任选一条配 Gitee 令牌 + **git bash**（`release.sh` 和那个脚本都是 bash）+ **python3**（脚本用它解析 Gitee 的接口返回；`python3` / `python` 任一个能调到就行）。Flutter 可以不装 —— `release.sh` 检测不到就跳过本地测试（打一行提醒），CI 里那遍照跑，测试红了不出包。别的都不用搬。

**发版失败了怎么办** —— 先认清是「GitHub 没包」还是「Gitee 没附件」：

```bash
gh release view vX.Y.Z --json assets      # 里面有没有 app-release.apk？
```

| 情况 | 判据 | 动作 |
|---|---|---|
| 构建、测试或产物断言红 | 没有包；`release.sh` 等十几分钟后就报错退出 | 当普通 CI 失败修，下个版本重发（tag 不能复用） |
| `Publish GitHub release` 红 | 没有包 | 先修 GitHub 侧，Gitee 这边补不了 |
| 包在 GitHub、Gitee 上没有发行版 | Gitee 网页该 tag 404 | 本机那步没跑完。重跑下面那条命令，脚本会自己把发行版建起来 |
| 上传中途断了 | 脚本报上传失败 | 重跑下面那条命令：脚本会先删掉上次留下的发行版再重建 |
| 附件大小对不上 | 脚本报「远端 X / 本地 Y」 | 上次传了半截：到 Gitee 网页删掉那份 `app-release.apk`，再重跑脚本 |
| 脚本说「删不掉，请手动删掉」 | 回滚失败 | 到 Gitee 网页把那个版本删掉 —— 留着的话国内用户会看到点不动的新版本 |

补传命令（幂等，重跑安全）：

```bash
bash scripts/gitee-attach.sh vX.Y.Z
```

五条规矩：

- **Gitee 只留最新 10 个发行版**：社区版配额是单附件 ≤100MB、**单仓库附件总量 1G**（一个包 21MB，不清理的话四十来版就传不上去了）。本机传完版会顺手删掉第 11 个起的旧发行版，**外加没有附件的空壳**；GitHub 那边没有总量限制，历史全留。删掉的老版本链接会失效（App 只读 `/releases/latest`，不受影响）。
- **不为一个附件再发一版**：新 tag 只会在 Gitee 多出一个同样没附件的空壳，旧版本照旧缺包。
- **补传是幂等的**：已有同名、同样大小的附件就跳过上传，重跑不会传第二份。
- **上传不带重试**：断了就重跑脚本。带重试的 POST 一旦在「服务端已收下、连接断了」时重发，会挂两份同名附件。
- **Gitee 上的版本必须带附件**：建发行版和传附件在同一步里，任一步失败就删掉刚建的那个 —— 于是「Gitee 上有某版本」与「它的包能下」永远等价。这是必须的：Gitee 的 `/releases/latest` **不跳过预发布**，空壳会被 App 当成新版本弹出来，点下载 404。

**关键配置**（已完成）：
- 正式签名：`CN=Findr` + 4 个 CI 密钥（`KEYSTORE_BASE64` / `*_PASSWORD` / `KEY_ALIAS`）
- Gitee 令牌：CI 侧用 GitHub 仓库密钥 `GITEE_TOKEN`（只给镜像那步推代码，不再建/删发行版）；本机侧用上面任一条配法（建发行版、传附件、清旧版）。
  换令牌的地方：GitHub 仓库 → Settings → Secrets and variables → Actions → `GITEE_TOKEN` → Update；
  或 `gh secret set GITEE_TOKEN --repo mos1128/findR`。**旧令牌不会因为覆盖而失效**，要自己去 Gitee
  私人令牌页撤销，否则它照样能推这个仓库。

**CI 三道断言**：
1. SQLite 含 FTS5 + trigram
2. 合并清单含 3 个权限
3. APK 签名是正式证书（非 `CN=Android Debug`）

**应用内更新**：
- 启动时静默检查（12 小时节流，失败不写节流），有新版本在首页设置入口打红点（`lib/state/update_check.dart`）
- 检查：先问 Gitee，失败再问 GitHub（读 `/releases/latest`）
- 下载：应用内下载（Gitee/GitHub 源可选）+ 浏览器下载兜底
- GitHub 源可走加速镜像：设置里开关 + **地址可自定义**（默认 `gh-proxy.com`，留空即不加速），失败**自动**回 GitHub 原站（`UpdateChannel.fallbackUrls`）
- 安装：下完拉系统安装界面，首次需允许「安装未知应用」
- 附件名：`app-release.apk`（CI 与 App 的约定）

**versionCode 自动推算**：`1.0.0` → 10000、`1.0.1` → 10001（`主×10000+次×100+修`）。

## 真机验收（16 条）

0. 自检两组全绿
1. 配置主 LLM → 探测通过
2. 录三类卡（物品/待办/流程）→ 分类位置正确、搜得到
3. 长按录音 → 能回放、能入库
4. **飞行模式**下录入 → 恢复网络后自动补跑
5. 录「护照/螺丝刀/插线板/剃须刀」→ 搜「出国玩该带啥」→ 出护照+剃须刀、不出螺丝刀
6. 导出备份 → 生成文件并调起分享面板
7. **换机**：备份存到 App 外 → 卸载 → 重装 → 导入 → 数据全回来
8. 检查更新 → 给版本或「已是最新」（断网给「无法获取更新信息」+前往下载页）
9. Gitee 更新 → 下载中切走/息屏 → 继续下 → 下完自动弹安装界面
10. GitHub 更新 + 断网测试 → 续传走通、浏览器下载兜底
11. 别的应用「分享到 Findr」：先**冷启动**分享一张图（App 没在后台），再**热启动**分享一段文字 →
    两种情况都要预填进录入条；图片保存后能打开（说明 `content://` 拷进 cache 成功）
12. 长按录音往上滑松手 → 这段录音**真的**丢掉：录入条不留附件、搜索页不进「正在转成文字」；
    松手后键盘不许自己弹回来（曾经补了一次轻点，录完音键盘就把录音态盖住了）
13. 按下就开麦：按住「按住 说话」那一颗，**第一个字**也要进录音（曾经垫了 200ms 才开录，
    真机反馈「要按很久才能说话」）；真点一下（<500ms）不留附件、不生成空卡
14. 药丸里只有一层字（曾经两层叠着画，字压字）；没打字时提示**水平居中**，打出来的字仍靠左
15. 检索页：从首页「搜索记忆」进来键盘直接起来 → 打着字按右下角「搜」出结果（没字时那颗是灰的）→
    点左下角麦克风 → 键盘收掉、药丸变成「按住 说话」→ 按住说、松手出结果；说着往上滑松手 → 作废、不留字；
    再点一下（图标变成键盘）→ 键盘回来、刚才听到的那句还在框里
16. 首页同理：点录入条左边那颗麦克风 → 药丸变成「按住 说话」、键盘收掉 → 按住说、松手存成一条；
    再点一下（图标变成键盘）→ 输入框回来、键盘自己起来

## 十二条铁律

1. 文档改一处要 grep 全捞
2. 「点不动」先想层叠遮挡
3. 「划不动」先看滚动容器
4. **动数据库必须先写测试押着**
5. 「调用失败」与「能力不支持」必须分开判（判据在 HTTP 层是否被接受）
6. 三态压成布尔时，**拿不准往 true 偏**（false 关功能，true 只白试一次）
7. 探测项只许覆盖真正在用的能力
8. **截断前先想清楚按什么排序**
9. 功能退役优先保留列，不动 schema
10. **推送前必须停下来，等用户确认没要改的了**
11. 同文件多个 Edit 串行发，改完 grep 核对
12. **用户反馈多数时候是对的**，先相信他

## 坑

- **平台插件别在首帧 await**（widget test 里永不返回）
- **图片 EXIF 有转两遍的坑**（当前已绕过）
- **令牌类叫 `Radii`**（`Radius` 撞 `dart:ui`）
- **release 包权限要自己声明**（见上）
- **`flutter build apk` 产物名不带 ABI**（用 glob 取，别赌名字）
- **Windows PowerShell 5.1 会把原生命令的 stderr 当错误**：`$ErrorActionPreference='Stop'` 下，`gh release view` 一句「release not found」（还没发完，本来正常）就能当场终止脚本，`2>$null` 拦不住（同样代码 PS 7 不会炸）。补传脚本原来就是 powershell 写的，为这类坑栽过一次后换成了 bash（`scripts/gitee-attach.sh`）：git bash 里一套写法到处一样，只用 python3 解析接口返回。

---

**产品规格、数据模型、Prompt 设计**：代码即文档，看 `findr_core/lib/` 各模块头部注释。
