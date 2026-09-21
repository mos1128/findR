/// findR 的核心逻辑 —— 纯 Dart，零 Flutter 依赖。
///
/// 本包是 `packages/core`（RN 时代的 TypeScript 实现）的 Dart 翻译版。
/// **TS 那份就是规格说明书**：按块译、每块用对应的 Dart 测试验收，别一口气译完。
///
/// 翻译顺序（从底层往上，依赖少的先做）—— 见 `Flutter迁移交接.md` 第 4.3 节：
///
/// 1. `db/`        schema + 迁移 + repository ← **进行中**（driver/schema/migrate/json/settings 已译完）
/// 2. `search/`    FTS5 检索 + 排序打分
/// 3. `providers/` 模型 HTTP 调用
/// 4. `parse/`     手写校验（替代 zod）
/// 5. `pipeline/`  录入流程编排
/// 6. `backup/`    .findrpack 导出/导入
///
/// 两条硬约束：
///
/// - **数据库走 `package:sqlite3` 3.x**：它用 Dart build hooks 自带预编译 SQLite
///   （默认编译选项含 `SQLITE_ENABLE_FTS5`）。**不要再依赖已废弃的 `sqlite3_flutter_libs`**
///   （0.6.0+eol 起它什么都不做）。
/// - **可逐字搬的两样别重写**：`prompts/templates.ts` 的字符串模板、以及所有 SQL 语句。
///
/// 检索的地基已实测通过（SQLite 3.53.4 / `ENABLE_FTS5` / trigram 下 3 字以上中文可命中），
/// 押注在 `test/fts5_trigram_test.dart`。
library;

export 'db/driver.dart';
export 'db/driver_sqlite3.dart';
export 'db/json.dart';
export 'db/migrate.dart';
export 'db/schema.dart';
export 'db/settings.dart';
