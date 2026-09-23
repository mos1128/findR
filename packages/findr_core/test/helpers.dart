import 'package:findr_core/findr_core.dart';

/// 测试里固定的「现在」。
///
/// 收在这里免得每个测试文件重复一遍。
final DateTime testNow = DateTime.parse('2026-03-01T00:00:00.000Z');

/// 开一个内存库并跑完迁移。
///
/// 用内存库而不是临时文件：每次都从零开始，且不碰磁盘
/// （`PRAGMA journal_mode = WAL` 在内存库上会被 SQLite 忽略，无副作用）。
SqliteDriver makeDb() {
  final db = Sqlite3Driver.openInMemory();
  migrate(db);
  return db;
}

/// 造一张卡片：给全字段默认值，测试里只传关心的那几项。
///
/// 参数一律可空 + 取默认值（含
/// `categoryId` 默认 `cat_item`、`entity` 默认 `测试实体`、时间戳默认 `2026-01-01`）。
MemoryCard makeCard({
  required String id,
  CardStatus? status,
  bool? needsOrganize,
  String? categoryId,
  String? entity,
  List<String>? pathIds,
  String? pathNames,
  List<StepItem>? steps,
  String? transcript,
  String? desc,
  List<String>? images,
  String? audioPath,
  bool? visionAnalyzed,
  List<String>? tags,
  double? confidence,
  String? ask,
  String? pathSuggestion,
  bool? pathMatched,
  SourceKind? source,
  int? retryCount,
  String? nextRetryAt,
  String? lastError,
  String? createdAt,
  String? updatedAt,
}) => MemoryCard(
  id: id,
  status: status ?? CardStatus.active,
  needsOrganize: needsOrganize ?? false,
  categoryId: categoryId ?? 'cat_item',
  entity: entity ?? '测试实体',
  pathIds: pathIds,
  pathNames: pathNames,
  steps: steps,
  transcript: transcript,
  desc: desc,
  images: images,
  audioPath: audioPath,
  visionAnalyzed: visionAnalyzed,
  tags: tags,
  confidence: confidence,
  ask: ask,
  pathSuggestion: pathSuggestion,
  pathMatched: pathMatched,
  source: source ?? SourceKind.text,
  retryCount: retryCount ?? 0,
  nextRetryAt: nextRetryAt,
  lastError: lastError,
  createdAt: createdAt ?? '2026-01-01T00:00:00.000Z',
  updatedAt: updatedAt ?? '2026-01-01T00:00:00.000Z',
);

/// 取某张表的列名（PRAGMA table_info 的 name 列）。
List<String> columnsOf(SqliteDriver db, String table) => db
    .prepare('PRAGMA table_info($table)')
    .all()
    .map((r) => r['name']!.toString())
    .toList();

/// 取 sqlite_master 里某类对象的名字。
List<String> objectsOf(SqliteDriver db, String type) => db
    .prepare('SELECT name FROM sqlite_master WHERE type = ?')
    .all([type])
    .map((r) => r['name']!.toString())
    .toList();
