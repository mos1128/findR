/// 卡片仓储。
///
/// 这一层是 core 与数据库的全部接触面：卡片的读写、分类与位置树的查询、
/// 检索 SQL 的拼装、队列取卡。上层（pipeline / search / backup）都只通过它碰库。
///
/// 几处刻意保持的写法（改动前先想清楚为什么这么写）：
///
/// - **参数一律包成列表**：Dart 没有变长参数，写成 `.get([a, b])`。
/// - **SQL 里的细节都是有意为之**，包括 `ESCAPE '\'`、`IS ?`（而不是 `= ?`，为了能绑 null）、
///   `bm25(cards_fts, 1.0, 3.0, 4.0, 2.0)` 的权重顺序。
/// - **时间一律走 `isoUtc()`**，恒为 UTC 的
///   `YYYY-MM-DDTHH:MM:SS.mmmZ` —— 这些字符串既是列值也是排序键，形状不能变。
library;

import 'dart:math';

import '../parse/outputs.dart';
import '../search/builder.dart';
import '../types.dart';
import '../util/iso.dart';
import 'driver.dart';
import 'json.dart';

/// 列清单。`needs_confirm` 已从读写两侧移除（角标、按钮、置位逻辑全删）——
/// **表里的那一列保留不动**：SQLite 删列要重建整张表（见 `schema.dart` 顶部第 3 条），
/// 而 `NOT NULL DEFAULT 0` 的残留列不写不读、零成本。老备份包带着它也能正常导入。
///
/// 这里**由列表拼串**，
/// 好处是两者不会漂移（`_insertSql` / `_upsertSql` 都从这里长出来）。
const List<String> cardColList = <String>[
  'id',
  'status',
  'needs_organize',
  'category_id',
  'entity',
  'path_ids',
  'path_names',
  'steps',
  'transcript',
  'desc_text',
  'images',
  'audio_path',
  'vision_analyzed',
  'tags',
  'confidence',
  'ask',
  'path_suggestion',
  'path_matched',
  'source',
  'retry_count',
  'next_retry_at',
  'last_error',
  'created_at',
  'updated_at',
];

/// 退避序列：1min → 5min → 30min → 2h → 次日；到上限后只留手动重试 / 批量补转写。
const List<int> retryBackoffMs = <int>[60000, 300000, 1800000, 7200000, 86400000];

/// 自动重试次数上限。写成从序列长度派生，避免「加了档位忘记改上限」。
final int maxAutoRetry = retryBackoffMs.length;

/// 传入本次失败后的 `retry_count`（已自增），返回下次可自动重试的延后毫秒数。
int computeBackoffMs(int retryCount) {
  var idx = retryCount < 1 ? 1 : retryCount;
  if (idx > retryBackoffMs.length) idx = retryBackoffMs.length;
  return retryBackoffMs[idx - 1];
}

final Random _rng = Random.secure();

/// 生成卡片 id（随机 UUID）。
///
/// Dart 侧不为此引包：用 `Random.secure()` 现场拼一个标准 v4 UUID —— 格式与
/// `crypto.randomUUID()` 完全一致（8-4-4-4-12 的十六进制、版本位 4、变体位 10）。
/// 格式必须一致的原因有两条：卡片 id 会进备份包（老包要能导进来），
/// 也会进媒体文件路径（`media/paths.dart` 拿它拼目录名）。
String makeId() {
  final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}'
      '-${hex.substring(16, 20)}-${hex.substring(20)}';
}

String? _strOrNull(Object? value) => value?.toString();

List<StepItem>? _parseSteps(Object? value) {
  if (value == null) return null;
  final raw = parseJsonArray<Map<String, Object?>>(value);
  if (raw == null) return null;
  return raw.map(StepItem.fromJson).toList();
}

Object? _stepsJson(Object? value) {
  if (value == null) return null;
  final steps = value as List<StepItem>;
  return steps.map((s) => s.toJson()).toList();
}

/// 数据库行 → 领域对象。
///
/// 三处**显式判型**的地方（行为取最保守的方向，各有注释）：
/// 未知 `status` 抛（NOT NULL + CHECK，读到别的就是数据坏了）；
/// 未知/空 `source` 降级为 text；`vision_analyzed` / `path_matched` 保留三态（null 不是 false）。
MemoryCard rowToCard(Map<String, Object?> row) => MemoryCard(
  id: row['id'].toString(),
  status: CardStatus.fromWire(row['status'].toString()),
  needsOrganize: row['needs_organize'] == 1,
  categoryId: _strOrNull(row['category_id']),
  entity: _strOrNull(row['entity']),
  pathIds: parseJsonArray<String>(row['path_ids']),
  pathNames: _strOrNull(row['path_names']),
  steps: _parseSteps(row['steps']),
  transcript: _strOrNull(row['transcript']),
  desc: _strOrNull(row['desc_text']),
  images: parseJsonArray<String>(row['images']),
  audioPath: _strOrNull(row['audio_path']),
  visionAnalyzed: row['vision_analyzed'] == null ? null : row['vision_analyzed'] == 1,
  tags: parseJsonArray<String>(row['tags']),
  confidence: (row['confidence'] as num?)?.toDouble(),
  ask: _strOrNull(row['ask']),
  pathSuggestion: _strOrNull(row['path_suggestion']),
  pathMatched: row['path_matched'] == null ? null : row['path_matched'] == 1,
  source: SourceKind.fromWire(row['source']),
  retryCount: (row['retry_count'] as num?)?.toInt() ?? 0,
  nextRetryAt: _strOrNull(row['next_retry_at']),
  lastError: _strOrNull(row['last_error']),
  createdAt: row['created_at'].toString(),
  updatedAt: row['updated_at'].toString(),
);

/// cards 行的绑定值，顺序与 [cardColList] 严格一致（insert / upsert 共用）。
List<Object?> _cardValues(MemoryCard card) => <Object?>[
  card.id,
  card.status.wire,
  card.needsOrganize ? 1 : 0,
  card.categoryId,
  card.entity,
  toJson(card.pathIds),
  card.pathNames,
  toJson(_stepsJson(card.steps)),
  card.transcript,
  card.desc,
  toJson(card.images),
  card.audioPath,
  card.visionAnalyzed == null ? null : (card.visionAnalyzed! ? 1 : 0),
  toJson(card.tags),
  card.confidence,
  card.ask,
  card.pathSuggestion,
  card.pathMatched == null ? null : (card.pathMatched! ? 1 : 0),
  card.source.wire,
  card.retryCount,
  card.nextRetryAt,
  card.lastError,
  card.createdAt,
  card.updatedAt,
];

String get _insertSql =>
    'INSERT INTO cards (${cardColList.join(', ')}) '
    'VALUES (${List.filled(cardColList.length, '?').join(',')})';

void insertCard(SqliteDriver db, MemoryCard card) {
  db.prepare(_insertSql).run(_cardValues(card));
}

/// 按 id 全字段写入，已存在则整行覆盖。
///
/// 备份导入用它：导入要还原的是「那一行的完整样子」，包括 status / source / retry_count
/// 这些不在 [updateCardFields] 白名单里的列（那是给用户编辑用的，不该让用户改这些）。
/// 是否覆盖由调用方按 `updatedAt` 判定 —— **本函数不自己判断新旧**。
void upsertCard(SqliteDriver db, MemoryCard card) {
  final updates = cardColList
      .where((c) => c != 'id')
      .map((c) => '$c = excluded.$c')
      .join(', ');
  db
      .prepare('$_insertSql ON CONFLICT(id) DO UPDATE SET $updates')
      .run(_cardValues(card));
}

MemoryCard? getCard(SqliteDriver db, String id) {
  final row = db.prepare('SELECT * FROM cards WHERE id = ?').get(<Object?>[id]);
  return row == null ? null : rowToCard(row);
}

/// P1 解析结果的落库字段。
///
/// `ask` / `pathSuggestion` / `pathMatched` 用可空表达「没有」—— 落库时三者都写 null。
final class ParsedCardFields {
  const ParsedCardFields({
    required this.categoryId,
    required this.entity,
    required this.pathIds,
    required this.pathNames,
    required this.steps,
    required this.desc,
    required this.tags,
    required this.confidence,
    required this.aliases,
    this.ask,
    this.pathSuggestion,
    this.pathMatched,
  });

  final String? categoryId;
  final String entity;
  final List<String>? pathIds;
  final String? pathNames;
  final List<StepItem>? steps;
  final String desc;
  final List<String> tags;
  final double? confidence;
  final List<String> aliases;
  final String? ask;
  final String? pathSuggestion;
  final bool? pathMatched;
}

const String _applyParseSql =
    "UPDATE cards SET status = 'active', last_error = NULL, retry_count = 0, next_retry_at = NULL, category_id = ?, "
    'entity = ?, path_ids = ?, path_names = ?, steps = ?, desc_text = ?, tags = ?, confidence = ?, '
    'ask = ?, path_suggestion = ?, path_matched = ?, updated_at = ? WHERE id = ?';

const String _insertAliasSql =
    "INSERT OR IGNORE INTO aliases (id, kind, name, card_id) VALUES (?, 'entity', ?, ?)";

void applyParseResult(
  SqliteDriver db,
  String id,
  ParsedCardFields f,
  DateTime now, {
  String Function() idGen = makeId,
}) {
  db.transaction(() {
    db
        .prepare(_applyParseSql)
        .run(<Object?>[
          f.categoryId,
          f.entity,
          toJson(f.pathIds),
          f.pathNames,
          toJson(_stepsJson(f.steps)),
          f.desc,
          toJson(f.tags),
          f.confidence,
          f.ask,
          f.pathSuggestion,
          f.pathMatched == null ? null : (f.pathMatched! ? 1 : 0),
          isoUtc(now),
          id,
        ]);
    for (final a in f.aliases) {
      final name = a.trim();
      if (name.isEmpty) continue;
      db.prepare(_insertAliasSql).run(<Object?>[idGen(), name, id]);
    }
  });
}

void markNeedsOrganize(SqliteDriver db, String id, DateTime now) {
  db
      .prepare(
        "UPDATE cards SET status = 'active', needs_organize = 1, updated_at = ? WHERE id = ?",
      )
      .run(<Object?>[isoUtc(now), id]);
}

/// 记一次可重试的失败：`retry_count` 自增，并按退避序列算出 `next_retry_at`。
///
/// 是否还能被队列自动捞起由 [listQueueCards] 的 `retry_count < maxAutoRetry` 决定 ——
/// 因此第 5 次失败仍会排期，但排完就只剩手动重试 / 批量补转写。
void markRetry(SqliteDriver db, String id, String error, DateTime now) {
  final nextCount = (getCard(db, id)?.retryCount ?? 0) + 1;
  final nextAt = isoUtc(
    DateTime.fromMillisecondsSinceEpoch(
      now.millisecondsSinceEpoch + computeBackoffMs(nextCount),
      isUtc: true,
    ),
  );
  db
      .prepare(
        'UPDATE cards SET retry_count = ?, last_error = ?, next_retry_at = ?, updated_at = ? '
        'WHERE id = ?',
      )
      .run(<Object?>[nextCount, error, nextAt, isoUtc(now), id]);
}

List<Category> listCategories(SqliteDriver db) => db
    .prepare('SELECT * FROM categories ORDER BY sort')
    .all()
    .map(
      (r) => Category(
        id: r['id'].toString(),
        name: r['name'].toString(),
        emoji: _strOrNull(r['emoji']),
        description: _strOrNull(r['description']),
        sort: (r['sort'] as num?)?.toInt() ?? 0,
        isPreset: r['is_preset'] == 1,
      ),
    )
    .toList();

List<LocationNode> listLocations(SqliteDriver db) => db
    .prepare('SELECT * FROM locations ORDER BY sort')
    .all()
    .map(
      (r) => LocationNode(
        id: r['id'].toString(),
        parentId: _strOrNull(r['parent_id']),
        name: r['name'].toString(),
        sort: (r['sort'] as num?)?.toInt() ?? 0,
      ),
    )
    .toList();

/// 插入（已存在**同父同名**则忽略）—— 注意与 `taxonomy.upsertLocationNode` 的区别：
/// 那个按 id 冲突更新，这个靠唯一索引挡重复，是 [ensurePath] 的「有就复用」实现。
void upsertLocation(SqliteDriver db, LocationNode node) {
  db
      .prepare('INSERT OR IGNORE INTO locations (id, parent_id, name, sort) VALUES (?, ?, ?, ?)')
      .run(<Object?>[node.id, node.parentId, node.name, node.sort]);
}

/// 判定码点是否属于「汉字」范畴。
///
/// 刻意不用正则的 `\p{Script=Han}` —— 因为部分运行时对 Unicode property escape
/// 的支持历来不稳（这条路径每次 P1 入库都会走到，一旦抛错整条录入链路就断了）。
/// Dart 侧本可以用 `RegExp(r'\p{Script=Han}', unicode: true)`，但**继续用码点区间**：
/// 一是两边行为必须逐字对齐（这条路径参与分类名匹配，判错就是路由错分类），
/// 二是区间写法没有正则引擎差异可言。
bool _isHanCodePoint(int cp) =>
    (cp >= 0x3400 && cp <= 0x4dbf) || // 扩展 A
    (cp >= 0x4e00 && cp <= 0x9fff) || // 基本区
    (cp >= 0xf900 && cp <= 0xfaff) || // 兼容表意文字
    (cp >= 0x20000 && cp <= 0x2ebef); // 扩展 B~F

bool _isAsciiAlphanumeric(int cp) =>
    (cp >= 0x30 && cp <= 0x39) || (cp >= 0x41 && cp <= 0x5a) || (cp >= 0x61 && cp <= 0x7a);

/// 只留汉字与 ASCII 字母数字，并转小写。
///
/// ⚠️ 迭代用 `String.runes`（**码点**）而不是 UTF-16 码元；
/// 若改用按 UTF-16 码元遍历的写法，扩展 B 区汉字（代理对）会被拆成两个半字符，
/// 判不进 [_isHanCodePoint] 而被丢掉。
String _normalizeCategoryName(String s) {
  final buf = StringBuffer();
  for (final cp in s.runes) {
    if (_isHanCodePoint(cp) || _isAsciiAlphanumeric(cp)) buf.writeCharCode(cp);
  }
  return buf.toString().toLowerCase();
}

/// 分类名匹配（容忍模型回显带 emoji / 空白 / 标点的变体）。
///
/// 先精确匹配，再「规范化后相等或互为子串」。子串这一层是必要的：
/// 模型常把分类名连着一句说明一起回显（「物品存取（item）」）。
String? resolveCategoryId(SqliteDriver db, String name) {
  final rows = listCategories(db);
  for (final c in rows) {
    if (c.name == name) return c.id;
  }
  final target = _normalizeCategoryName(name);
  if (target.isEmpty) return null;
  for (final c in rows) {
    final n = _normalizeCategoryName(c.name);
    if (n.isNotEmpty && (n == target || target.contains(n) || n.contains(target))) {
      return c.id;
    }
  }
  return null;
}

/// 按位置名逐级匹配已有位置树；任一级失配返回 null。
///
/// **只读、不建节点** —— 需要「匹配不到就创建」的场景请用 [ensurePath]。
/// `parent_id IS ?`（不是 `= ?`）是为了让根节点的 null 也能参与比较。
({List<String> ids, String namesStr})? resolvePath(SqliteDriver db, List<String> names) {
  final ids = <String>[];
  String? parent;
  for (final name in names) {
    final row = db
        .prepare('SELECT id FROM locations WHERE name = ? AND parent_id IS ?')
        .get(<Object?>[name, parent]);
    if (row == null) return null;
    final id = row['id'].toString();
    ids.add(id);
    parent = id;
  }
  return (ids: ids, namesStr: names.join('/'));
}

/// 在指定父节点下找同名（或同别名）的位置 id；找不到返回 null。
String? _findLocationIdUnder(SqliteDriver db, String name, String? parentId) {
  // 别名优先：模型或用户可能用「睡房」指代已经建好的「主卧」
  final viaAlias = db
      .prepare(
        'SELECT l.id FROM aliases a JOIN locations l ON l.id = a.location_id '
        "WHERE a.kind = 'location' AND a.name = ? AND l.parent_id IS ?",
      )
      .get(<Object?>[name, parentId]);
  if (viaAlias != null) return viaAlias['id'].toString();

  final direct = db
      .prepare('SELECT id FROM locations WHERE name = ? AND parent_id IS ?')
      .get(<Object?>[name, parentId]);
  return _strOrNull(direct?['id']);
}

/// 同级下一个排序值（表上有 `(COALESCE(parent_id,''), name)` 唯一索引，重名插不进去）。
int _nextLocationSort(SqliteDriver db, String? parentId) {
  final row = db
      .prepare('SELECT MAX(sort) AS m FROM locations WHERE parent_id IS ?')
      .get(<Object?>[parentId]);
  return ((row?['m'] as num?)?.toInt() ?? -1) + 1;
}

/// 逐级解析位置路径，**缺失的层级直接落库新建**，返回实际使用的 id 链。
///
/// 为什么不是「失配就交给用户去建」：位置树本该由解析结果**增量长出来** ——
/// 用户说「放在次卧的左侧床头柜了」，有就复用、没有就新建。让用户先去设置里手工把房间建好、
/// 再回来点选，等于把「模型会产出什么词」这个无从预知的责任推给了用户；
/// 而且位置树若一直是空的，用户连选都没得选。
/// 用户仍然可以改（卡片里的「位置」一栏），但那从「必须」变成了「可选」。
///
/// [created] 列出本次真正新建的层级名：界面据此标出「新位置」并让用户确认一次，
/// 避免模型偶尔产出奇怪层级时无声无息地污染位置树。
({List<String> ids, String namesStr, List<String> created}) ensurePath(
  SqliteDriver db,
  List<String> rawNames, {
  String Function() idGen = makeId,
}) {
  final names = rawNames.map((n) => n.trim()).where((n) => n.isNotEmpty).toList();
  final ids = <String>[];
  final created = <String>[];
  String? parent;

  for (final name in names) {
    final existing = _findLocationIdUnder(db, name, parent);
    if (existing != null) {
      ids.add(existing);
      parent = existing;
      continue;
    }
    final id = idGen();
    upsertLocation(
      db,
      LocationNode(id: id, parentId: parent, name: name, sort: _nextLocationSort(db, parent)),
    );
    ids.add(id);
    created.add(name);
    parent = id;
  }

  return (ids: ids, namesStr: names.join('/'), created: created);
}

/// 别名命中后把实体规范名补进检索词。
List<String> expandTermsByAliases(SqliteDriver db, List<String> terms) {
  final extra = <String>[];
  for (final t in terms) {
    final row = db
        .prepare(
          'SELECT c.entity FROM aliases a JOIN cards c ON c.id = a.card_id WHERE a.name = ?',
        )
        .get(<Object?>[t]);
    final entity = _strOrNull(row?['entity']);
    if (entity != null &&
        entity.isNotEmpty &&
        !terms.contains(entity) &&
        !extra.contains(entity)) {
      extra.add(entity);
    }
  }
  return extra;
}

/// LIKE 降级路径给固定低优先分：`bm25` 是正数（越小越相关），
/// 用 1e9 保证「FTS 命中永远排在纯 LIKE 命中前面」，同时又不至于在数值上溢出。
const double _likeFallbackScore = 1e9;

/// 混合检索执行器：≥3 字词走 FTS trigram（bm25 权重 transcript 1.0 / desc 3.0 /
/// entity 4.0 / tags 2.0），<3 字词走 LIKE 降级。any 模式两路并集（FTS 优先）；
/// all 模式 FTS 命中且 AND 所有短词。
///
/// 恒定条件：`status='active'`。结果按 score 升序（bm25 越小越相关；LIKE 命中固定低优先）、
/// `created_at` 降序。
List<MemoryCard> executeSearch(SqliteDriver db, BuiltSearch s) {
  final filters = <String>["c.status = 'active'"];
  final filterParams = <Object?>[];
  if (s.categoryId != null) {
    filters.add('c.category_id = ?');
    filterParams.add(s.categoryId);
  }
  if (s.sinceIso != null) {
    filters.add('c.created_at >= ?');
    filterParams.add(s.sinceIso);
  }
  if (s.pathPrefixLike != null) {
    filters.add(r"c.path_names LIKE ? ESCAPE '\'");
    filterParams.add(s.pathPrefixLike);
  }
  final filterSql = filters.isEmpty ? '' : ' AND ${filters.join(' AND ')}';

  final hits = <String, ({MemoryCard card, double score, String createdAt})>{};
  void addRows(List<Map<String, Object?>> rows, double? fallbackScore) {
    for (final r in rows) {
      final card = rowToCard(r);
      final score = fallbackScore ?? (r['score'] as num).toDouble();
      final prev = hits[card.id];
      // 同一张卡两路都命中时留分更小的那条（FTS 的 bm25 优先于 LIKE 的固定低优先分）
      if (prev == null || prev.score > score) {
        hits[card.id] = (card: card, score: score, createdAt: card.createdAt);
      }
    }
  }

  final likeTermConds = <String>[];
  final likeTermParams = <Object?>[];
  for (final t in s.likeTerms) {
    final p = '%${escapeLike(t)}%';
    likeTermParams.addAll(<Object?>[p, p, p, p]);
    likeTermConds.add(
      "(c.desc_text LIKE ? ESCAPE '\\' OR c.transcript LIKE ? ESCAPE '\\' "
      "OR c.entity LIKE ? ESCAPE '\\' OR c.tags LIKE ? ESCAPE '\\')",
    );
  }

  final ftsExpr = s.ftsExpr;
  if (ftsExpr != null) {
    var sql =
        'SELECT c.*, bm25(cards_fts, 1.0, 3.0, 4.0, 2.0) AS score FROM cards_fts '
        'JOIN cards c ON c.rowid = cards_fts.rowid WHERE cards_fts MATCH ?$filterSql';
    final params = <Object?>[ftsExpr, ...filterParams];
    if (s.matchMode == MatchMode.all && likeTermConds.isNotEmpty) {
      sql += ' AND ${likeTermConds.join(' AND ')}';
      params.addAll(likeTermParams);
    }
    addRows(db.prepare(sql).all(params), null);
    if (s.matchMode == MatchMode.any && likeTermConds.isNotEmpty) {
      final sql2 =
          'SELECT c.* FROM cards c WHERE (${likeTermConds.join(' OR ')})$filterSql';
      addRows(db.prepare(sql2).all(<Object?>[...likeTermParams, ...filterParams]), _likeFallbackScore);
    }
  } else if (likeTermConds.isNotEmpty) {
    final joiner = s.matchMode == MatchMode.all ? ' AND ' : ' OR ';
    final sql = 'SELECT c.* FROM cards c WHERE (${likeTermConds.join(joiner)})$filterSql';
    addRows(db.prepare(sql).all(<Object?>[...likeTermParams, ...filterParams]), _likeFallbackScore);
  }

  final sorted = hits.values.toList()
    ..sort((a, b) {
      final byScore = a.score.compareTo(b.score);
      if (byScore != 0) return byScore;
      // created_at 降序（字符串比较）。两边完全相同时给 0（稳定排序，顺序确定）——
      // 只在「同分且同一时刻」这种理论上不存在的组合上才有差别。
      return b.createdAt.compareTo(a.createdAt);
    });
  return sorted.take(s.limit).map((h) => h.card).toList();
}

// ─────────────────────────────────────────────────────────────
// 记忆流读取与卡片编辑
// ─────────────────────────────────────────────────────────────

/// [listCards] / [countCards] 的筛选条件。
final class ListCardsOptions {
  const ListCardsOptions({
    this.limit,
    this.offset,
    this.categoryId,
    this.statuses,
    this.includeArchived = false,
  });

  final int? limit;
  final int? offset;
  final String? categoryId;

  /// 显式指定要哪些生命周期状态；不传则按 [includeArchived] 决定。
  final List<CardStatus>? statuses;

  /// 默认排除 archived。**草稿（pending / pending_transcript）恒定可见** ——
  /// 否则飞行模式录入的卡在 UI 上等于不存在，用户会以为丢了。
  final bool includeArchived;
}

/// [listCards] 与 [countCards] 共用的 WHERE 构造（收成一个，不抄两遍）。
({List<String> where, List<Object?> params}) _statusWhere(ListCardsOptions opts) {
  final where = <String>[];
  final params = <Object?>[];
  final statuses = opts.statuses;
  if (statuses != null && statuses.isNotEmpty) {
    where.add('status IN (${List.filled(statuses.length, '?').join(', ')})');
    params.addAll(statuses.map((s) => s.wire));
  } else if (!opts.includeArchived) {
    where.add("status <> 'archived'");
  }
  final categoryId = opts.categoryId;
  // 空串的 categoryId 同样跳过
  if (categoryId != null && categoryId.isNotEmpty) {
    where.add('category_id = ?');
    params.add(categoryId);
  }
  return (where: where, params: params);
}

List<MemoryCard> listCards(
  SqliteDriver db, [
  ListCardsOptions opts = const ListCardsOptions(),
]) {
  final w = _statusWhere(opts);
  final sql =
      'SELECT * FROM cards'
      '${w.where.isNotEmpty ? ' WHERE ${w.where.join(' AND ')}' : ''}'
      ' ORDER BY created_at DESC LIMIT ? OFFSET ?';
  final params = <Object?>[...w.params, opts.limit ?? 50, opts.offset ?? 0];
  return db.prepare(sql).all(params).map(rowToCard).toList();
}

int countCards(SqliteDriver db, [ListCardsOptions opts = const ListCardsOptions()]) {
  final w = _statusWhere(opts);
  final sql =
      'SELECT COUNT(*) AS n FROM cards'
      '${w.where.isNotEmpty ? ' WHERE ${w.where.join(' AND ')}' : ''}';
  final row = db.prepare(sql).get(w.params);
  return (row?['n'] as num?)?.toInt() ?? 0;
}

/// 「用户能改哪些列」的白名单，顺序即 SQL 里 SET 子句的顺序
/// （顺序与 `CARD_PATCH_COLUMNS` 一致，便于对照）。
///
/// **只写 patch 里出现过的键**：用 [unset] 表达「这次不动这一列」——
/// 等价于「键在 patch 里就取它的值」。
/// 各字段期望的类型写在字段注释里（用 Object? 承载「键不存在 = 不动这一列」）。
final class CardPatch {
  const CardPatch({
    this.categoryId = unset,
    this.entity = unset,
    this.pathIds = unset,
    this.pathNames = unset,
    this.steps = unset,
    this.transcript = unset,
    this.desc = unset,
    this.images = unset,
    this.tags = unset,
    this.ask = unset,
    this.pathSuggestion = unset,
    this.pathMatched = unset,
    this.lastError = unset,
  });

  /// `String?`
  final Object? categoryId;

  /// `String?`
  final Object? entity;

  /// `List<String>?`（JSON 列）
  final Object? pathIds;

  /// `String?`
  final Object? pathNames;

  /// `List<StepItem>?`（JSON 列）
  final Object? steps;

  /// `String?`
  final Object? transcript;

  /// `String?`（列名 `desc_text`）
  final Object? desc;

  /// `List<String>?`（JSON 列）
  final Object? images;

  /// `List<String>?`（JSON 列）
  final Object? tags;

  /// `String?`
  final Object? ask;

  /// `String?`
  final Object? pathSuggestion;

  /// `bool?`（落库转 0/1，三态保留）
  final Object? pathMatched;

  /// `String?`（错误信息，可传 null 清除）
  final Object? lastError;
}

/// 按白名单更新卡片字段，恒定刷新 `updated_at`。**只写 patch 里出现的键。**
void updateCardFields(SqliteDriver db, String id, CardPatch patch, DateTime now) {
  final sets = <String>[];
  final params = <Object?>[];

  void put(String col, Object? value) {
    sets.add('$col = ?');
    params.add(value);
  }

  void putJson(String col, Object? value) => put(col, toJson(value));

  void putTriBool(String col, Object? value) =>
      put(col, value == null ? null : ((value as bool) ? 1 : 0));

  // 顺序与 CARD_PATCH_COLUMNS 一致
  if (!identical(patch.categoryId, unset)) put('category_id', patch.categoryId);
  if (!identical(patch.entity, unset)) put('entity', patch.entity);
  if (!identical(patch.pathIds, unset)) putJson('path_ids', patch.pathIds);
  if (!identical(patch.pathNames, unset)) put('path_names', patch.pathNames);
  if (!identical(patch.steps, unset)) putJson('steps', _stepsJson(patch.steps));
  if (!identical(patch.transcript, unset)) put('transcript', patch.transcript);
  if (!identical(patch.desc, unset)) put('desc_text', patch.desc);
  if (!identical(patch.images, unset)) putJson('images', patch.images);
  if (!identical(patch.tags, unset)) putJson('tags', patch.tags);
  if (!identical(patch.ask, unset)) put('ask', patch.ask);
  if (!identical(patch.pathSuggestion, unset)) put('path_suggestion', patch.pathSuggestion);
  if (!identical(patch.pathMatched, unset)) putTriBool('path_matched', patch.pathMatched);
  if (!identical(patch.lastError, unset)) {
    put('last_error', patch.lastError);
    if (patch.lastError == null) {
      put('retry_count', 0);
      put('next_retry_at', null);
    }
  }

  if (sets.isEmpty) return;
  sets.add('updated_at = ?');
  params.add(isoUtc(now));
  params.add(id);
  db.prepare('UPDATE cards SET ${sets.join(', ')} WHERE id = ?').run(params);
}

/// 终态：本次录入既没有可送模型的图片、也没有文本（图片分析关闭 + 无文字）。
/// 需求 5.1 允许用户坚持存为「纯图片卡片」—— `desc` 为空，只能靠分类和标签检索。
///
/// 这里不再打「待确认」：纯图片卡没有正文可核对，点一下
/// 「确认信息无误」也不改变任何数据，标记只是凭空多一个角标。分类想改随时能改。
void markPlainCard(SqliteDriver db, String id, DateTime now) {
  db
      .prepare("UPDATE cards SET status = 'active', desc_text = NULL, updated_at = ? WHERE id = ?")
      .run(<Object?>[isoUtc(now), id]);
}

void clearNeedsOrganize(SqliteDriver db, String id, DateTime now) {
  db
      .prepare(
        'UPDATE cards SET needs_organize = 0, last_error = NULL, retry_count = 0, next_retry_at = NULL, updated_at = ? WHERE id = ?',
      )
      .run(<Object?>[isoUtc(now), id]);
}

void setVisionAnalyzed(SqliteDriver db, String id, bool value, DateTime now) {
  db
      .prepare('UPDATE cards SET vision_analyzed = ?, updated_at = ? WHERE id = ?')
      .run(<Object?>[value ? 1 : 0, isoUtc(now), id]);
}

void setCardStatus(SqliteDriver db, String id, CardStatus status, DateTime now) {
  db
      .prepare('UPDATE cards SET status = ?, updated_at = ? WHERE id = ?')
      .run(<Object?>[status.wire, isoUtc(now), id]);
}

/// 补文字 / 转写回填：写入 transcript 并清掉补问，同时把待转写推进到待解析。
/// 需求四「打字则跳过转写」—— 已经有文本就不该再送去转写。
void setTranscript(SqliteDriver db, String id, String text, DateTime now) {
  db
      .prepare(
        "UPDATE cards SET transcript = ?, ask = NULL, "
        "status = CASE WHEN status = 'pending_transcript' THEN 'pending' ELSE status END, "
        'updated_at = ? WHERE id = ?',
      )
      .run(<Object?>[text, isoUtc(now), id]);
}

/// 删除卡片并连带清掉它的别名；媒体文件由平台层按 `images` / `audio_path` 回收。
void deleteCard(SqliteDriver db, String id) {
  db.transaction(() {
    db.prepare('DELETE FROM aliases WHERE card_id = ?').run(<Object?>[id]);
    db.prepare('DELETE FROM cards WHERE id = ?').run(<Object?>[id]);
  });
}

/// [listQueueCards] 的选项。
final class QueueQueryOptions {
  const QueueQueryOptions({this.statuses});

  /// 默认待转写 + 待解析；**没配 ASR 时调用方应只传 `[CardStatus.pending]`**，
  /// 否则一串待转写卡会堵在队头，后面的卡永远轮不到。
  final List<CardStatus>? statuses;
}

/// 队列取卡：待处理、未达自动重试上限、且已过退避时间。
List<MemoryCard> listQueueCards(
  SqliteDriver db,
  DateTime now, {
  int limit = 20,
  QueueQueryOptions opts = const QueueQueryOptions(),
}) {
  final statuses =
      opts.statuses ??
      const <CardStatus>[CardStatus.pendingTranscript, CardStatus.pending];
  if (statuses.isEmpty) return <MemoryCard>[];
  final placeholders = List.filled(statuses.length, '?').join(', ');
  final rows = db
      .prepare(
        'SELECT * FROM cards '
        'WHERE status IN ($placeholders) '
        '  AND retry_count < ? '
        '  AND (next_retry_at IS NULL OR next_retry_at <= ?) '
        'ORDER BY created_at ASC '
        'LIMIT ?',
      )
      .all(<Object?>[...statuses.map((s) => s.wire), maxAutoRetry, isoUtc(now), limit]);
  return rows.map(rowToCard).toList();
}

/// 「批量补转写」：无视退避与上限，把所有待转写卡片重置为可立刻重试。
int resetTranscriptRetries(SqliteDriver db, DateTime now) {
  final r = db
      .prepare(
        'UPDATE cards SET retry_count = 0, next_retry_at = NULL, last_error = NULL, '
        "updated_at = ? WHERE status = 'pending_transcript'",
      )
      .run(<Object?>[isoUtc(now)]);
  return r.changes;
}
