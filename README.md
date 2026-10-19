# findr_app —— Findr 的 Flutter 工程（安卓）

Findr（长程记忆助手）的**安卓客户端**。仓库根就是它；`lib/` 里只放**平台接线 + 界面**，纯逻辑不在这。

> **仓库结构**：根目录 = 这个 Flutter app，`packages/findr_core/` = 共享逻辑包。
> 两者用 **Dart 官方的 pub workspaces** 统一解析 ⇒ 全仓只有一份 `pubspec.lock` / `.dart_tool/`，
> **在仓库根跑一次 `flutter pub get` 就够**（别进 `packages/` 单独 pub get）。

| 目录 | 放什么 |
|---|---|
| `lib/platform/` | 设备侧实现：DB 驱动、媒体读写、安全存储、备份、运行时（`runtime`）、检查更新与下载（`update`）、安装与保活通道（`update_install`）|
| `lib/capture/` | 录入链路：拍照/相册、压缩、录音、文本文件、提交 |
| `lib/ui/` | 通用组件（`kit.dart` 基础件、卡片行、媒体查看、音频回放、更新进度小图标 `update_pill`）|
| `lib/screens/` | 页面：记忆流主页、卡片详情、设置（5 屏）+ 自检屏 |
| `lib/state/` | Riverpod 状态（含 `update_download`：应用内更新的下载状态机）|
| `lib/theme/` | 设计令牌（配色 / 圆角 / 间距）|
| `assets/branding/` | 品牌素材（图标 / 启动图）—— **已接入**；改图形只改 `tool/gen_icons.dart` 顶部常量，参数与坑见该目录的 README |

**纯逻辑在 `packages/findr_core/`**（零 Flutter 依赖的纯 Dart 包：数据库 / 检索 / 模型调用 / 备份格式）。
那边的测试是主验收网（300 条，`dart test`），这里的 widget 测试是补充（117 条，`flutter test`）。

## 常用命令

```bash
flutter pub get
flutter analyze
flutter test
flutter run                 # 需要连着设备
bash release.sh             # 发版：改版本号 → 打 tag → 推 GitHub（CI 出包并同步 Gitee，见 docs/开发指南.md 5.6）
```

⚠️ 本机没装 Android SDK 时**出包只能走 CI**（`.github/workflows/flutter.yml` 的 `apk` 作业）。

## 两个必须知道的坑

1. **release 包必须自己声明 `INTERNET` 权限**
   （`android/app/src/main/AndroidManifest.xml`）。
   没有任何插件会替你带它，而 Flutter 模板在 `debug/`、`profile/` 清单里自带
   ⇒ **`flutter run` 一切正常、release 包装到真机后所有域名解析失败**
   （`Failed host lookup`，真机验收时踩到过）。CI 里有一道产物级断言挡着 ——
   同一道断言还看着应用内更新的两个：`REQUEST_INSTALL_PACKAGES`（拉系统安装界面）
   与 `FOREGROUND_SERVICE_DATA_SYNC`（下载时的保活前台服务），它们同样只在真机上才炸。

2. **平台插件别放在首帧的关键路径上 `await`**
   （`package_info_plus` 这类在 widget test 宿主里永不返回，界面会一直转圈）。
   做法见 `lib/platform/runtime.dart`：先返回，再 `unawaited` 补版本号。

## 文档

都在 `docs/`（只有本 README 在根目录）。**新会话第一份读《开发指南》**。

| 文档 | 讲什么 |
|---|---|
| [开发指南](docs/开发指南.md) | **新会话第一份读**：环境搭建、踩坑记录、十二条铁律、工程约定、真机验收、当前状态与待办 |
| [需求](docs/需求.md) | 产品要什么：定位与三条红线、功能模块、交互、字段的**业务含义**、验收口径 |
| [技术设计](docs/技术设计.md) | 数据模型与 DDL、Provider 适配、录入流水线、检索实现、备份格式、测试策略、CI 与发布 |
| [Prompt 设计](docs/prompt设计.md) | 四段 prompt 的设计意图、行为约束与调用侧约定（**文案本身在代码里**：`packages/findr_core/lib/prompts/`）|
| [图标与启动图](assets/branding/README.md) | 改图标只看这份：设计稿参数、66dp 安全区、安卓 13+ 主题图标怎么画 |

> 就这 5 份（+ 本 README），各有唯一职责、互不重复。**别再新增文档** ——
> 新内容并进上面最接近的那份，一主题一权威。
