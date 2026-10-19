/// manifest 的生成与合并。
///
/// 导出侧的安全原则：
/// settings 走**白名单** —— 只有 [SettingsKeys.all] 里列出的键可能进包，再叠一层按键名剥除，
/// **而不是「过滤掉看起来像密钥的」**。方向反过来，才能在将来有人往 settings 里塞新东西时
/// 默认是「不导出」而不是「导出」。API Key 本身只在系统安全存储里，压根不在 settings 表里。
///
/// ⚠️ **「备份不含 Key」这条已放开，但白名单本身没变**：
/// Key 走 manifest 的 `apiKeys` **单独字段**（见 `types.dart`），由平台层显式传入。
/// 所以这里**仍然不许**把 Key 混进 settings —— 两个通道分开，才能各管各的开关与风险提示。
library;

import 'dart:convert' show jsonEncode;

import '../db/driver.dart';
import '../db/repository.dart';
import '../db/settings.dart';
import '../settings.dart';
import '../types.dart';
import '../util/iso.dart';
import 'format.dart';
import 'types.dart';

/// 按键名判定「看起来是机密」—— 这是白名单之外的**第二层**兜底。
final RegExp _secretKeyPattern = RegExp(
  r'(api[_-]?key|secret|token|password|passphrase|credential|biometric|生物锁|指纹|face)',
  caseSensitive: false,
);

Object? _stripSecrets(Object? value) {
  if (value is List) return value.map(_stripSecrets).toList();
  if (value is Map) {
    final out = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key.toString();
      if (_secretKeyPattern.hasMatch(key)) continue;
      out[key] = _stripSecrets(entry.value);
    }
    return out;
  }
  return value;
}

/// 供导出使用的非机密设置：**白名单键 + 深度剥除**。
Map<String, Object?> publicSettings(SqliteDriver db) {
  final all = listSettings(db);
  final out = <String, Object?>{};
  for (final key in SettingsKeys.all) {
    if (all.containsKey(key)) out[key] = _stripSecrets(all[key]);
  }
  return out;
}

/// 备份范围是「**全部表**」：归档卡也要进包，否则换机后归档过的记忆会凭空消失。
List<MemoryCard> readAllCards(SqliteDriver db) =>
    db.prepare('SELECT * FROM cards').all().map(rowToCard).toList();

List<BackupCategory> _readCategories(SqliteDriver db) => db
    .prepare('SELECT * FROM categories ORDER BY sort')
    .all()
    .map(
      (r) => BackupCategory(
        id: r['id'].toString(),
        name: r['name'].toString(),
        emoji: r['emoji'] as String?,
        description: r['description'] as String?,
        sort: (r['sort'] as num).toInt(),
        isPreset: r['is_preset'] == 1,
      ),
    )
    .toList();

List<BackupLocation> _readLocations(SqliteDriver db) => db
    .prepare('SELECT * FROM locations ORDER BY sort')
    .all()
    .map(
      (r) => BackupLocation(
        id: r['id'].toString(),
        parentId: r['parent_id'] as String?,
        name: r['name'].toString(),
        sort: (r['sort'] as num).toInt(),
      ),
    )
    .toList();

List<BackupAlias> _readAliases(SqliteDriver db) => db
    .prepare('SELECT * FROM aliases')
    .all()
    .map(
      (r) => BackupAlias(
        id: r['id'].toString(),
        kind: r['kind'].toString(),
        name: r['name'].toString(),
        cardId: r['card_id'] as String?,
        locationId: r['location_id'] as String?,
      ),
    )
    .toList();

/// 卡片引用到的媒体相对路径全集（**去重**）。
///
/// DB 里可能引用已回收的文件，读取侧按缺失处理（见 `pack.dart` 的 `mediaMissing`）。
List<String> collectMediaPaths(List<MemoryCard> cards) {
  final set = <String>{};
  for (final c in cards) {
    for (final p in c.images ?? const <String>[]) {
      if (p.isNotEmpty) set.add(p);
    }
    final audio = c.audioPath;
    if (audio != null) set.add(audio);
  }
  return set.toList();
}

final class BuiltManifest {
  const BuiltManifest({required this.manifest, required this.mediaPaths});

  final BackupManifest manifest;
  final List<String> mediaPaths;
}

/// 组装 manifest（`media` 索引此时还是空的，由 `pack.dart` 实际写完文件后回填）。
BuiltManifest buildManifest(
  SqliteDriver db,
  int schemaVersionValue,
  DateTime now, [
  String? appVersion,
]) {
  final cards = readAllCards(db);
  return BuiltManifest(
    manifest: BackupManifest(
      format: 'findrpack',
      formatVersion: backupFormatVersion,
      schemaVersion: schemaVersionValue,
      // ⚠️ 走 isoUtc() —— **不是** `toIso8601String()`。
      exportedAt: isoUtc(now),
      appVersion: appVersion,
      cards: cards,
      categories: _readCategories(db),
      locations: _readLocations(db),
      aliases: _readAliases(db),
      settings: publicSettings(db),
      media: const <MediaEntryMeta>[],
    ),
    mediaPaths: collectMediaPaths(cards),
  );
}

// ─────────────────────────────────────────────────────────────
// 导入合并
// ─────────────────────────────────────────────────────────────

/// 可变累加器。
///
/// [ImportReport] 对外不可变，而导入过程需要边跑边记账，
/// 所以内部先用这个可变的壳，跑完再一次性转成 `ImportReport`。
final class ReportAcc {
  int cardsInserted = 0;
  int cardsUpdated = 0;
  int cardsKeptLocal = 0;
  int categoriesInserted = 0;
  int categoriesKeptLocal = 0;
  int locationsInserted = 0;
  int locationsKeptLocal = 0;
  int aliasesInserted = 0;
  int settingsWritten = 0;
  int settingsKeptLocal = 0;
  int remappedCategoryRefs = 0;
  int remappedLocationRefs = 0;
  int droppedRefs = 0;
  final List<BackupConflict> conflicts = <BackupConflict>[];

  ImportReport toReport() => ImportReport(
    cardsInserted: cardsInserted,
    cardsUpdated: cardsUpdated,
    cardsKeptLocal: cardsKeptLocal,
    categoriesInserted: categoriesInserted,
    categoriesKeptLocal: categoriesKeptLocal,
    locationsInserted: locationsInserted,
    locationsKeptLocal: locationsKeptLocal,
    aliasesInserted: aliasesInserted,
    settingsWritten: settingsWritten,
    settingsKeptLocal: settingsKeptLocal,
    mediaWritten: 0,
    mediaOverwritten: 0,
    remappedCategoryRefs: remappedCategoryRefs,
    remappedLocationRefs: remappedLocationRefs,
    droppedRefs: droppedRefs,
    conflicts: conflicts,
  );
}

/// 合并策略：按 id 幂等 upsert、`updated_at` 新者胜、
/// **不删除本地任何数据**、分类/位置同名冲突保留本地并把外来 id 重映射到本地 id。
///
/// 只碰 DB；媒体文件由 `pack.dart` 在调用本函数**之前**写入磁盘。
ImportReport mergeManifest(SqliteDriver db, BackupManifest manifest) {
  final acc = ReportAcc();
  db.transaction(() {
    final categoryIdMap = _mergeCategories(db, manifest.categories, acc);
    final locationIdMap = _mergeLocations(db, manifest.locations, acc);
    _mergeCards(db, manifest, categoryIdMap, locationIdMap, acc);
    _mergeAliases(db, manifest.aliases, acc);
    _mergeSettings(db, manifest.settings, acc);
  });
  return acc.toReport();
}

Map<String, String> _mergeCategories(
  SqliteDriver db,
  List<BackupCategory> incoming,
  ReportAcc acc,
) {
  final map = <String, String>{};
  for (final c in incoming) {
    final byId = db.prepare('SELECT id FROM categories WHERE id = ?').get(<Object?>[c.id]);
    if (byId != null) {
      map[c.id] = c.id;
      acc.categoriesKeptLocal++;
      continue;
    }
    // 同名不同 id：保留本地那条，把外来 id 映射过去。
    // 刻意不往 aliases 写这条（原设想是「写进 aliases」，但 aliases.kind 只有
    // entity/location 两种，且分类名一致时 resolveCategoryId 本来就按名字命中本地分类，
    // 补一条空挂在 aliases 里只会留垃圾行）。冲突记进报告，由 UI 决定要不要提示用户。
    final byName = db.prepare('SELECT id FROM categories WHERE name = ?').get(<Object?>[c.name]);
    if (byName != null) {
      final localId = byName['id'].toString();
      map[c.id] = localId;
      acc.categoriesKeptLocal++;
      acc.conflicts.add(
        BackupConflict(kind: 'category', importedId: c.id, localId: localId, name: c.name),
      );
      continue;
    }
    db
        .prepare(
          'INSERT INTO categories (id, name, emoji, description, sort, is_preset) '
          'VALUES (?, ?, ?, ?, ?, ?)',
        )
        .run(<Object?>[c.id, c.name, c.emoji, c.description, c.sort, c.isPreset ? 1 : 0]);
    map[c.id] = c.id;
    acc.categoriesInserted++;
  }
  return map;
}

/// 父节点必须先于子节点落库，否则外键直接拒。
/// **按「父链深度」排序而不是按 manifest 顺序** —— manifest 里的顺序不可信。
List<BackupLocation> _orderByDepth(List<BackupLocation> locations) {
  final byId = <String, BackupLocation>{for (final l in locations) l.id: l};

  int depth(BackupLocation l) {
    var d = 0;
    var cur = l.parentId;
    final seen = <String>{l.id};
    while (cur != null && byId.containsKey(cur) && !seen.contains(cur)) {
      seen.add(cur);
      d++;
      cur = byId[cur]!.parentId;
    }
    return d;
  }

  final copy = <BackupLocation>[...locations];
  copy.sort((a, b) => depth(a) - depth(b));
  return copy;
}

Map<String, String> _mergeLocations(
  SqliteDriver db,
  List<BackupLocation> incoming,
  ReportAcc acc,
) {
  final map = <String, String>{};
  for (final l in _orderByDepth(incoming)) {
    final byId = db.prepare('SELECT id FROM locations WHERE id = ?').get(<Object?>[l.id]);
    if (byId != null) {
      map[l.id] = l.id;
      acc.locationsKeptLocal++;
      continue;
    }

    // 父节点也要跟着重映射（父可能因同名冲突被换成了本地 id）
    final rawParent = l.parentId;
    var parentId = rawParent != null ? map[rawParent] : null;
    if (rawParent != null && parentId == null) {
      final exists = db.prepare('SELECT id FROM locations WHERE id = ?').get(<Object?>[rawParent]);
      parentId = exists != null ? rawParent : null;
      if (parentId == null) acc.droppedRefs++;
    }

    final byName = db
        .prepare('SELECT id FROM locations WHERE name = ? AND parent_id IS ?')
        .get(<Object?>[l.name, parentId]);
    if (byName != null) {
      final localId = byName['id'].toString();
      map[l.id] = localId;
      acc.locationsKeptLocal++;
      acc.conflicts.add(
        BackupConflict(kind: 'location', importedId: l.id, localId: localId, name: l.name),
      );
      continue;
    }

    db
        .prepare('INSERT INTO locations (id, parent_id, name, sort) VALUES (?, ?, ?, ?)')
        .run(<Object?>[l.id, parentId, l.name, l.sort]);
    map[l.id] = l.id;
    acc.locationsInserted++;
  }
  return map;
}

String? _locationNames(SqliteDriver db, List<String> ids) {
  final names = <String>[];
  for (final id in ids) {
    final row = db.prepare('SELECT name FROM locations WHERE id = ?').get(<Object?>[id]);
    if (row == null) return null;
    names.add(row['name'].toString());
  }
  return names.join('/');
}

/// `Iterable.firstOrNull` 需要 `package:collection`；这里手写一个，免得为一个用两次的
/// 小工具引入依赖。（`dart:core` 的 `Iterable` 没有带谓词的 firstOrNull。）
T? _firstOrNull<T>(Iterable<T> items, bool Function(T) test) {
  for (final item in items) {
    if (test(item)) return item;
  }
  return null;
}

/// 复制一张卡片并替换少数几个字段。
MemoryCard _copyCard(
  MemoryCard c, {
  required String? categoryId,
  required List<String>? pathIds,
  required String? pathNames,
}) => MemoryCard(
  id: c.id,
  status: c.status,
  needsOrganize: c.needsOrganize,
  categoryId: categoryId,
  entity: c.entity,
  pathIds: pathIds,
  pathNames: pathNames,
  steps: c.steps,
  transcript: c.transcript,
  desc: c.desc,
  images: c.images,
  audioPath: c.audioPath,
  visionAnalyzed: c.visionAnalyzed,
  tags: c.tags,
  confidence: c.confidence,
  ask: c.ask,
  pathSuggestion: c.pathSuggestion,
  pathMatched: c.pathMatched,
  source: c.source,
  retryCount: c.retryCount,
  nextRetryAt: c.nextRetryAt,
  lastError: c.lastError,
  createdAt: c.createdAt,
  updatedAt: c.updatedAt,
);

void _mergeCards(
  SqliteDriver db,
  BackupManifest manifest,
  Map<String, String> categoryIdMap,
  Map<String, String> locationIdMap,
  ReportAcc acc,
) {
  for (final card in manifest.cards) {
    final local = db
        .prepare('SELECT id, updated_at FROM cards WHERE id = ?')
        .get(<Object?>[card.id]);
    final localUpdatedAt = local?['updated_at']?.toString();

    if (local != null && !(card.updatedAt.compareTo(localUpdatedAt!) > 0)) {
      // updated_at 相同或本地更新 → 本地胜。**同值也判本地胜**，
      // 避免同一份包导入两次来回抖动（第二次导入必须是幂等的）。
      acc.cardsKeptLocal++;
      continue;
    }

    var nextCategoryId = card.categoryId;

    // 外键重映射：导入的分类/位置 id 在本地可能是另一个 id（同名冲突），也可能压根没来
    if (nextCategoryId != null) {
      final mapped = categoryIdMap[nextCategoryId] ?? nextCategoryId;
      final exists = db.prepare('SELECT id FROM categories WHERE id = ?').get(<Object?>[mapped]);
      if (exists != null) {
        if (mapped != nextCategoryId) acc.remappedCategoryRefs++;
        nextCategoryId = mapped;
      } else {
        final src = _firstOrNull(manifest.categories, (c) => c.id == nextCategoryId);
        final byName = src != null ? resolveCategoryId(db, src.name) : null;
        nextCategoryId = byName;
        if (byName != null) {
          acc.remappedCategoryRefs++;
        } else {
          acc.droppedRefs++;
        }
      }
    }

    var nextPathIds = card.pathIds;
    var nextPathNames = card.pathNames;
    final idsIn = nextPathIds;
    if (idsIn != null && idsIn.isNotEmpty) {
      final mapped = <String>[];
      var allMapped = true;
      for (final id in idsIn) {
        final to = locationIdMap[id] ?? id;
        final exists = db.prepare('SELECT id FROM locations WHERE id = ?').get(<Object?>[to]);
        if (exists != null) {
          if (to != id) allMapped = false;
          mapped.add(to);
        } else {
          allMapped = false;
        }
      }
      if (!allMapped) {
        acc.remappedLocationRefs += mapped.length;
        acc.droppedRefs += idsIn.length - mapped.length;
        nextPathIds = mapped.isNotEmpty ? mapped : null;
        // path_names 是 path_ids 的反规范化副本，id 变了就必须跟着重算，
        // 否则检索会拿旧名字匹配
        nextPathNames = mapped.isNotEmpty ? _locationNames(db, mapped) : null;
      }
    }

    upsertCard(
      db,
      _copyCard(
        card,
        categoryId: nextCategoryId,
        pathIds: nextPathIds,
        pathNames: nextPathNames,
      ),
    );
    if (local != null) {
      acc.cardsUpdated++;
    } else {
      acc.cardsInserted++;
    }
  }
  // manifest 里没有的卡片保持原样 —— 「不删除本地任何数据」是硬约束，这里刻意什么都不做
}

void _mergeAliases(SqliteDriver db, List<BackupAlias> incoming, ReportAcc acc) {
  for (final a in incoming) {
    // (kind, name) 唯一约束：导入包里与本地重名的别名会被 IGNORE 掉，这符合「保留本地」
    final r = db
        .prepare(
          'INSERT OR IGNORE INTO aliases (id, kind, name, card_id, location_id) '
          'VALUES (?, ?, ?, ?, ?)',
        )
        .run(<Object?>[a.id, a.kind, a.name, a.cardId, a.locationId]);
    if (r.changes > 0) acc.aliasesInserted++;
  }
}

void _mergeSettings(SqliteDriver db, Map<String, Object?> incoming, ReportAcc acc) {
  for (final entry in incoming.entries) {
    // 只补本地没有的键：同一台机器上重复导入不该把用户改过的设置冲掉
    final exists = db.prepare('SELECT key FROM settings WHERE key = ?').get(<Object?>[entry.key]);
    if (exists != null) {
      acc.settingsKeptLocal++;
      continue;
    }
    db
        .prepare('INSERT INTO settings (key, value) VALUES (?, ?)')
        .run(<Object?>[entry.key, jsonEncode(entry.value)]);
    acc.settingsWritten++;
  }
}
