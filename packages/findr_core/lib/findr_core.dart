/// findR 的核心逻辑 —— 纯 Dart，零 Flutter 依赖。
///
/// 纯 Dart 实现：数据库、检索、模型调用、备份格式。
/// **改动按块来，每块用对应的测试验收**，别一口气全动。
///
/// 分层（从底层往上，依赖少的先做）：
///
/// 1. `types` + `util` + `db/`（driver / schema / migrate / json / settings /
///    repository / taxonomy）
/// 2. `search/`（builder / inventory / advise / answer / service）——
///    连同它依赖的 `prompts/`（模板 + 渲染）、`parse/`（手写校验）一起
/// 3. `providers/` 全部（types / fake / **sse / samples / media / openai_compat /
///    anthropic / capabilities / factory**）+ `settings.dart` + `util/base64` + `util/utf8`
/// 4. `pipeline/` 录入流程编排（capture / edit / queue / ingest）+ `cards/badges` + `media/paths`
/// 5. `backup/` `.findrpack` 导出/导入（crc32 / format / zip / manifest / pack）
/// 6. UI（在**仓库根**的 `lib/`）
///
/// 三条硬约束：
///
/// - **数据库走 `package:sqlite3` 3.x**：它用 Dart build hooks 自带预编译 SQLite
///   （默认编译选项含 `SQLITE_ENABLE_FTS5`）。**不要再依赖已废弃的 `sqlite3_flutter_libs`**
///   （0.6.0+eol 起它什么都不做）。
/// - **HTTP 走 `package:http`**：`providers/` 是唯一出网的一层，
///   测试注入假 `http.Client` 即可换掉整条网络。
/// - **两样东西别重写**：`prompts/templates.dart` 的字符串模板、以及所有 SQL 语句。
///
/// 检索的地基已实测通过（SQLite 3.53.4 / `ENABLE_FTS5` / trigram 下 3 字以上中文可命中），
/// 自检逻辑在 `selfcheck.dart`，第 1 层押注在 `test/selfcheck_test.dart`。
/// ⚠️ 但**第 1 层不算命门通过** —— 还要在 App 的自检屏（Flutter/真机）上跑同一份检查。
///
/// `unset` 是对外隐藏的：它只在 `CardPatch` / `copyWith` 的**形参默认值**里出现，
/// 调用方永远不需要写出它（要用的是「不传这个参数」）。
library;

export 'backup/crc32.dart';
export 'backup/format.dart';
export 'backup/manifest.dart';
export 'backup/pack.dart';
export 'backup/types.dart';
export 'backup/zip.dart';
export 'cards/badges.dart';
export 'db/driver.dart';
export 'db/driver_sqlite3.dart';
export 'db/json.dart';
export 'db/migrate.dart';
export 'db/repository.dart';
export 'db/schema.dart';
export 'db/settings.dart';
export 'db/taxonomy.dart';
export 'media/paths.dart';
export 'parse/model_json.dart';
export 'parse/outputs.dart';
export 'parse/schema.dart';
export 'pipeline/capture.dart';
export 'pipeline/edit.dart';
export 'pipeline/ingest.dart';
export 'pipeline/queue.dart';
export 'prompts/render.dart';
export 'providers/anthropic.dart';
export 'providers/capabilities.dart';
export 'providers/factory.dart';
export 'providers/fake.dart';
export 'providers/media.dart';
export 'providers/openai_compat.dart';
export 'providers/openai_responses.dart';
export 'providers/samples.dart';
export 'providers/sse.dart';
export 'providers/types.dart';
export 'search/advise.dart';
export 'search/answer.dart';
export 'search/builder.dart';
export 'search/inventory.dart';
export 'search/service.dart';
export 'selfcheck.dart';
export 'settings.dart';
export 'types.dart' hide unset;
export 'util/base64.dart';
export 'util/iso.dart';
export 'util/utf8.dart';
// 刻意**不导出** `providers/transport.dart`：它是这几个适配器共用的内部小件
// （URL 归一化、超时、读体、JSON 取值），不是对外契约；导出去只会污染顶层命名空间。
