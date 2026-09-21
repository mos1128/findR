/// findR 的核心逻辑 —— 纯 Dart，零 Flutter 依赖。
///
/// 本包是 `packages/core`（RN 时代的 TypeScript 实现）的 Dart 翻译版。
/// **TS 那份就是规格说明书**：按块译、每块用对应的 Dart 测试验收，别一口气译完。
///
/// 翻译顺序（从底层往上，依赖少的先做）—— 见 `Flutter迁移交接.md` §4.3 / §6.2：
///
/// 1. ✅ `types` + `util` + `db/`（driver / schema / migrate / json / settings /
///    repository / taxonomy）
/// 2. ✅ `search/`（builder / inventory / advise / answer / service）——
///    连同它的三个直接依赖一起立起来了：`prompts/`（模板 + 渲染）、
///    `parse/`（手写校验替代 zod）、`providers/` 的**类型契约**（HTTP 实现仍待译）
/// 3. ⬜ `providers/` 的 HTTP 实现（openai-compat / anthropic / capabilities / factory / sse）
/// 4. ⬜ `pipeline/` 录入流程编排
/// 5. ⬜ `backup/` `.findrpack` 导出/导入
/// 6. ⬜ `cards/` + `media/` + `settings`
///
/// 两条硬约束：
///
/// - **数据库走 `package:sqlite3` 3.x**：它用 Dart build hooks 自带预编译 SQLite
///   （默认编译选项含 `SQLITE_ENABLE_FTS5`）。**不要再依赖已废弃的 `sqlite3_flutter_libs`**
///   （0.6.0+eol 起它什么都不做）。
/// - **可逐字搬的两样别重写**：`prompts/templates.dart` 的字符串模板、以及所有 SQL 语句。
///
/// 检索的地基已实测通过（SQLite 3.53.4 / `ENABLE_FTS5` / trigram 下 3 字以上中文可命中），
/// 押注在 `test/fts5_trigram_test.dart`。
///
/// `unset` 是对外隐藏的：它只在 `CardPatch` / `copyWith` 的**形参默认值**里出现，
/// 调用方永远不需要写出它（要用的是「不传这个参数」）。
library;

export 'db/driver.dart';
export 'db/driver_sqlite3.dart';
export 'db/json.dart';
export 'db/migrate.dart';
export 'db/repository.dart';
export 'db/schema.dart';
export 'db/settings.dart';
export 'db/taxonomy.dart';
export 'parse/model_json.dart';
export 'parse/outputs.dart';
export 'parse/schema.dart';
export 'prompts/render.dart';
export 'providers/fake.dart';
export 'providers/types.dart';
export 'search/advise.dart';
export 'search/answer.dart';
export 'search/builder.dart';
export 'search/inventory.dart';
export 'search/service.dart';
export 'types.dart' hide unset;
export 'util/iso.dart';
