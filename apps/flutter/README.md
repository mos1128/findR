# findr_app —— Findr 的 Flutter 壳（安卓）

Findr（长程记忆助手）的**安卓客户端**。这里是**平台接线 + 界面**，纯逻辑不在这。

| 目录 | 放什么 |
|---|---|
| `lib/platform/` | 设备侧实现：DB 驱动、媒体读写、安全存储、备份、运行时（`runtime`）|
| `lib/capture/` | 录入链路：拍照/相册、压缩、录音、文本文件、提交 |
| `lib/ui/` | 通用组件（`kit.dart` 基础件、卡片行、媒体查看、音频回放）|
| `lib/screens/` | 页面：记忆流主页、卡片详情、设置（5 屏）+ 自检屏 |
| `lib/state/` | Riverpod 状态 |
| `assets/branding/` | 品牌素材（图标 / 启动图）—— **尚未接入**，见该目录的 README |

**纯逻辑在 `packages/findr_core/`**（零 Flutter 依赖的纯 Dart 包：数据库 / 检索 / 模型调用 / 备份格式）。
那边的测试是主验收网（296 条），这里的 widget 测试是补充（90 条）。

## 常用命令

```bash
flutter pub get
flutter analyze
flutter test
flutter run                 # 需要连着设备
```

⚠️ 本机没装 Android SDK 时**出包只能走 CI**（`.github/workflows/flutter.yml` 的 `apk` 作业）。

## 两个必须知道的坑

1. **release 包必须自己声明 `INTERNET` 权限**
   （`android/app/src/main/AndroidManifest.xml`）。
   没有任何插件会替你带它，而 Flutter 模板在 `debug/`、`profile/` 清单里自带
   ⇒ **`flutter run` 一切正常、release 包装到真机后所有域名解析失败**
   （`Failed host lookup`，2026-09-23 真机验收时踩到）。CI 里有一道产物级断言挡着。

2. **平台插件别放在首帧的关键路径上 `await`**
   （`package_info_plus` 这类在 widget test 宿主里永不返回，界面会一直转圈）。
   做法见 `lib/platform/runtime.dart`：先返回，再 `unawaited` 补版本号。

## 文档

项目文档都在仓库根目录。**新会话第一份读 `Flutter迁移交接.md`**（唯一权威，含铁律与环境坑）。
