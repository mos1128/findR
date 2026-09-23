# findr_core

findR 的**纯 Dart 核心逻辑** —— 零 Flutter 依赖，可以 `dart test` 直接跑，不必起 Flutter 环境。

它同时被 V1 的安卓 app（仓库根那个 Flutter 工程）和将来的 V2 / V3 桌面版复用，所以刻意不碰
任何 UI 或平台 API：**所有文件 IO、网络、安全存储都由调用方注入**。

## 里面有什么

| 目录 | 职责 |
|---|---|
| `db/` | SQLite 驱动抽象、schema 与迁移、仓储、设置、分类与位置树 |
| `search/` | FTS5 + LIKE 混合检索、别名扩展、L1 定位、L2 答案组织、L3 建议裁决 |
| `providers/` | 模型调用（anthropic / OpenAI 兼容 / SSE 流 / 能力探测 / 假 Provider 供测试）|
| `parse/` | 模型输出的手写校验（替代 TS 侧的 zod）|
| `pipeline/` | 录入流水线编排（capture / edit / queue / ingest）|
| `backup/` | `.findrpack` 备份格式（crc32 / format / zip / manifest / pack）|
| `prompts/` | Prompt 模板与渲染注入 |
| `cards/` `media/` `util/` | 角标、媒体相对路径规划、base64 与 UTF-8 工具 |
| `selfcheck.dart` | 迁移命门（FTS5 + trigram）的可复用自检，App 自检屏与测试共用同一份逻辑 |

## 两条硬约束

1. **数据库只走 `package:sqlite3` 3.x** —— 它用 Dart build hooks 自带预编译 SQLite
   （默认编译选项含 `SQLITE_ENABLE_FTS5`）。**不要再依赖已废弃的 `sqlite3_flutter_libs`**。
2. **HTTP 只走 `package:http`** —— `providers/` 是唯一出网的一层。测试注入假 `http.Client`
   就能换掉整条网络。

## 依赖解析

本包是仓库根那个 **pub workspace** 的成员（`pubspec.yaml` 里写了 `resolution: workspace`）。

⇒ **不要在 `packages/findr_core/` 里单独 `pub get`**。在**仓库根**跑一次 `flutter pub get` 即可，
全仓共用一份 `pubspec.lock` 与 `.dart_tool/`。

## 常用命令

在 `packages/findr_core/` 下：

```bash
dart analyze
dart test
```
