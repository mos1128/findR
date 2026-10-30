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

**基线不许破**：core 300 条 + app 124 条，静态分析干净。

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
- **当前明文**，导出前必须弹确认框告知
- 导出走 `settings_public` 白名单（**不是黑名单**），core 有 canary 断言
- API Key 可选带走（`apiKeys` 字段，平台层显式传入，core 只搬不读）
- 完整性全靠 ZIP 的 CRC32

### 数据库
- 表：`cards` / `locations` / `categories` / `aliases` / `settings` / FTS 影子表
- DDL 在 `findr_core/lib/db/schema.dart`，逐条 exec
- **SQLite 删列必须重建整张表** → 退役功能优先保留列、只摘读写

### 检索三级
1. **L1 本地**：P2 查询理解 → 本地 FTS5/LIKE，0 结果逐级放宽（去 category → 去 path/time → all 转 any）
2. **L2 答案组织**：top-8 片段送 P3 → 答案卡片（**永不发全库**）
3. **L3 建议裁决**：整库清单（先按相关度排序再截断 200 条）送 P4 → 必需/看情况/还缺什么

意图路由：定位题（护照在哪）走 L1+L2；推理题（出国该带啥）走 L3。

### 图标与启动图
- 改图只改 `tool/gen_icons.dart` 顶部常量，然后 `dart run tool/gen_icons.dart` 一次重出全部尺寸，别手改位图
- **品牌蓝两处同步**：脚本 `kBlue` 与 `values/colors.xml` 的 `brand_blue`（图标背景层与启动屏都引用它）
- **内容必须落在直径 66dp 安全区内**（半径 33dp），脚本结尾会打一行自检，显示 ❌ 就是 `kContentScale` 调大了
- **单色层（主题图标）只有形状有意义**：卡片画描边、定位针实心并留 `kMonoGap` 空隙；照彩色稿画实心会糊成一块色块
- 换图标覆盖安装即可，**不用卸载**（只有换签名才要）

## 发布流程

```bash
bash release.sh
# 输入新版本号（X.Y.Z，每次最后一位+1）
# 输入更新说明（手写，进 tag 注释）
# → 跑测试 → 改 pubspec.yaml → 提交 → 打 tag → 推 GitHub
```

**CI 自动**：构建 APK → 发 GitHub → 镜像代码到 Gitee → 建 Gitee 发行版传同一个 APK。

**关键配置**（已完成）：
- 正式签名：`CN=Findr` + 4 个 CI 密钥（`KEYSTORE_BASE64` / `*_PASSWORD` / `KEY_ALIAS`）
- Gitee 令牌：`GITEE_TOKEN`（GitHub 仓库密钥）

**CI 三道断言**：
1. SQLite 含 FTS5 + trigram
2. 合并清单含 3 个权限
3. APK 签名是正式证书（非 `CN=Android Debug`）

**应用内更新**：
- 启动时静默检查（12 小时节流，失败不写节流），有新版本在首页设置入口打红点（`lib/state/update_check.dart`）
- 检查：先问 Gitee，失败再问 GitHub（读 `/releases/latest`）
- 下载：应用内下载（Gitee/GitHub 源可选）+ 浏览器下载兜底
- GitHub 源先走国内加速镜像 `gh-proxy.com`，失败**自动**回 GitHub 原站（`UpdateChannel.fallbackUrls`）
- 安装：下完拉系统安装界面，首次需允许「安装未知应用」
- 附件名：`app-release.apk`（CI 与 App 的约定）

**versionCode 自动推算**：`1.0.0` → 10000、`1.0.1` → 10001（`主×10000+次×100+修`）。

## 真机验收（10 条）

0. 自检两组全绿
1. 配置主 LLM → 探测通过
2. 录三类卡（物品/待办/流程）→ 分类位置正确、搜得到
3. 长按录音 → 能回放、能入库
4. **飞行模式**下录入 → 恢复网络后自动补跑
5. 录「护照/螺丝刀/插线板/剃须刀」→ 搜「出国玩该带啥」→ 出护照+剃须刀、不出螺丝刀
6. 导出备份 → 先弹「没加密」确认
7. **换机**：备份存到 App 外 → 卸载 → 重装 → 导入 → 数据全回来
8. 检查更新 → 给版本或「已是最新」（断网给「拿不到更新信息」+前往下载页）
9. Gitee 更新 → 下载中切走/息屏 → 继续下 → 下完自动弹安装界面
10. GitHub 更新 + 断网测试 → 续传走通、浏览器下载兜底

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

---

**产品规格、数据模型、Prompt 设计**：代码即文档，看 `findr_core/lib/` 各模块头部注释。
