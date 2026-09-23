/// 备份（`.findrpack`）的容器与端口定义 —— 逐字对应
/// `packages/core/src/backup/types.ts`（120 行）。
///
/// 两条硬约束来自《技术设计.md》第七节，改动前先读那一节：
///   1. **settings 走白名单** —— 导出侧只放 `settings_public`（见 manifest.dart），
///      不是「过滤掉看起来像密钥的」，而是「只放白名单里的」，**方向反过来才对**。
///   2. **core 不直接依赖任何文件实现** —— RN 侧与 node 测试侧各自注入（见 [MediaStorePort]）。
///
/// ⚠️ **API Key 可随包带走（2026-09-23 用户决定，属需求变更）**：见 [BackupManifest.apiKeys]。
/// 它**不在** settings 白名单里（白名单那条没动），而是单独一个可选字段，
/// 由平台层在导出时显式传入 —— 这样「带不带」的开关留在界面上，core 不做默认。
///
/// ⚠️ **当前不做加密**（2026-09-20 决策）：备份文件是明文 ZIP，谁拿到谁能读。
/// 这里已经没有 CryptoPort 了；加密回归时按 `format.dart` 里写的那套（提 [backupFormatVersion]）
/// 再加端口。**别提前把端口加回来放着** —— 没有调用方的接口只会腐烂。
///
/// Dart 侧的两处对应关系：
/// - TS 的 `MaybePromise<T>` ⇒ Dart 用 SDK 自带的 `FutureOr<T>`（`dart:async`），语义完全相同；
/// - TS 的**可选方法** `exists?` ⇒ Dart 接口不支持可选成员，改成**可空的函数类型 getter**
///   （为 null 即「未实现」）。调用点的判断方式与 TS 一模一样。
library;

import 'dart:async';
import 'dart:typed_data';

import '../types.dart';

/// 媒体文件读写端口。
///
/// 相对路径就是 DB 里存的相对路径（`files/cards/202609/<cardId>/01.webp`），
/// **绝对根目录由平台层拼**（见 `media/paths.dart`）。
abstract interface class MediaStorePort {
  /// 文件不存在返回 null，**不抛错**：DB 可能引用已被回收、或拍完没保存的路径。
  FutureOr<Uint8List?> read(String relPath);

  FutureOr<void> write(String relPath, Uint8List data);

  /// 只判存在。为 null 表示未实现 —— 导入侧退化为 read 一次（结果相同，只是多读一遍文件）。
  FutureOr<bool> Function(String relPath)? get exists;
}

/// ZIP 内的媒体成员索引，导入时用来校验完整性。
final class MediaEntryMeta {
  const MediaEntryMeta({required this.path, required this.size, required this.crc32});

  factory MediaEntryMeta.fromJson(Map<String, Object?> json) => MediaEntryMeta(
    path: (json['path'] ?? '').toString(),
    size: (json['size'] as num?)?.toInt() ?? 0,
    crc32: (json['crc32'] as num?)?.toInt() ?? 0,
  );

  final String path;
  final int size;
  final int crc32;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'size': size,
    'crc32': crc32,
  };
}

final class BackupCategory {
  const BackupCategory({
    required this.id,
    required this.name,
    required this.emoji,
    required this.description,
    required this.sort,
    required this.isPreset,
  });

  factory BackupCategory.fromJson(Map<String, Object?> json) => BackupCategory(
    id: (json['id'] ?? '').toString(),
    name: (json['name'] ?? '').toString(),
    emoji: json['emoji'] as String?,
    description: json['description'] as String?,
    sort: (json['sort'] as num?)?.toInt() ?? 0,
    isPreset: json['isPreset'] == true,
  );

  final String id;
  final String name;
  final String? emoji;
  final String? description;
  final int sort;
  final bool isPreset;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'emoji': emoji,
    'description': description,
    'sort': sort,
    'isPreset': isPreset,
  };
}

final class BackupLocation {
  const BackupLocation({
    required this.id,
    required this.parentId,
    required this.name,
    required this.sort,
  });

  factory BackupLocation.fromJson(Map<String, Object?> json) => BackupLocation(
    id: (json['id'] ?? '').toString(),
    parentId: json['parentId'] as String?,
    name: (json['name'] ?? '').toString(),
    sort: (json['sort'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String? parentId;
  final String name;
  final int sort;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'parentId': parentId,
    'name': name,
    'sort': sort,
  };
}

final class BackupAlias {
  const BackupAlias({
    required this.id,
    required this.kind,
    required this.name,
    required this.cardId,
    required this.locationId,
  });

  factory BackupAlias.fromJson(Map<String, Object?> json) => BackupAlias(
    id: (json['id'] ?? '').toString(),
    kind: (json['kind'] ?? '').toString(),
    name: (json['name'] ?? '').toString(),
    cardId: json['cardId'] as String?,
    locationId: json['locationId'] as String?,
  );

  final String id;

  /// TS 是 `'entity' | 'location'` 的字面量 union。
  /// 这里保留 [String] 而不是 enum：`aliases.kind` 由 SQL 的 CHECK 约束把关，
  /// 而导入是要**原样还原**外来包里的值（真出现第三种，先照搬再用 SQL 报错，比静默丢弃好）。
  final String kind;

  final String name;
  final String? cardId;
  final String? locationId;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind,
    'name': name,
    'cardId': cardId,
    'locationId': locationId,
  };
}

/// 备份清单。JSON 键名与 TS 逐字段对齐 —— **这是跨版本/跨端互认的契约，改不得**。
final class BackupManifest {
  const BackupManifest({
    required this.format,
    required this.formatVersion,
    required this.schemaVersion,
    required this.exportedAt,
    required this.appVersion,
    required this.cards,
    required this.categories,
    required this.locations,
    required this.aliases,
    required this.settings,
    required this.media,
    this.apiKeys,
  });

  factory BackupManifest.fromJson(Map<String, Object?> json) => BackupManifest(
    format: (json['format'] ?? '').toString(),
    formatVersion: (json['formatVersion'] as num?)?.toInt() ?? 0,
    schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 0,
    exportedAt: (json['exportedAt'] ?? '').toString(),
    appVersion: json['appVersion'] as String?,
    cards: _listOf(json['cards'], cardFromJson),
    categories: _listOf(json['categories'], BackupCategory.fromJson),
    locations: _listOf(json['locations'], BackupLocation.fromJson),
    aliases: _listOf(json['aliases'], BackupAlias.fromJson),
    settings: (json['settings'] as Map?)?.cast<String, Object?>() ?? <String, Object?>{},
    // ⚠️ **null 与空数组在这里语义不同**：老包可能压根没有 `media` 键
    // （TS 的 `manifest.media?.length ?? mediaEntries.length` 正是靠这个区分），
    // 所以「键不存在」要保留成 null，不能塌成 `[]`。
    media: json.containsKey('media') ? _listOf(json['media'], MediaEntryMeta.fromJson) : null,
    // 老包没有这个键 ⇒ null（「没带 Key」），与「带了但为空」不是一回事。
    apiKeys: (json['apiKeys'] as Map?)?.map(
      (k, v) => MapEntry<String, String>(k.toString(), v.toString()),
    ),
  );

  final String format;
  final int formatVersion;
  final int schemaVersion;
  final String exportedAt;

  /// 仅用于排查，不参与合并决策。
  final String? appVersion;

  final List<MemoryCard> cards;
  final List<BackupCategory> categories;
  final List<BackupLocation> locations;
  final List<BackupAlias> aliases;

  /// 非机密设置（**绝不含 Key / 生物锁**）。
  final Map<String, Object?> settings;

  final List<MediaEntryMeta>? media;

  /// 随包带走的 API Key（**明文**，键名与 `ApiKeySlot.storageKey` 对齐）。
  ///
  /// ⚠️ **2026-09-23 用户决定：换机后重填 Key 太麻烦，所以备份默认带走。**
  /// 代价写在界面上（导出确认框 + 备份页红条）：**包是不加密的，带 Key 等于
  /// 把密钥明文交给任何拿到这个文件的人**。别在别处悄悄默认带上。
  ///
  /// `null` = 这份包没带 Key（老包 / 用户在导出时关掉了）；空 map = 带了但一把都没有。
  /// core **不自己读 Key**（它在 Keystore 里，只有平台层够得着），只负责搬运。
  final Map<String, String>? apiKeys;

  /// 回填媒体索引（`pack.ts` 写完文件后才能算出 size/crc32）。
  ///
  /// TS 那边是 `manifest.media = mediaMeta` 直接改字段；Dart 的 [BackupManifest] 不可变，
  /// 所以换成「造一份新的」——语义相同，调用点更短。
  BackupManifest withMediaList(List<MediaEntryMeta> mediaList) => BackupManifest(
    format: format,
    formatVersion: formatVersion,
    schemaVersion: schemaVersion,
    exportedAt: exportedAt,
    appVersion: appVersion,
    cards: cards,
    categories: categories,
    locations: locations,
    aliases: aliases,
    settings: settings,
    media: mediaList,
    apiKeys: apiKeys,
  );

  /// 挂上要随包带走的 Key。传 null / 空 map 都表示「这份包不带 Key」。
  BackupManifest withApiKeys(Map<String, String>? keys) => BackupManifest(
    format: format,
    formatVersion: formatVersion,
    schemaVersion: schemaVersion,
    exportedAt: exportedAt,
    appVersion: appVersion,
    cards: cards,
    categories: categories,
    locations: locations,
    aliases: aliases,
    settings: settings,
    media: media,
    apiKeys: keys,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'format': format,
    'formatVersion': formatVersion,
    'schemaVersion': schemaVersion,
    'exportedAt': exportedAt,
    // TS 那边 `appVersion` 为 undefined 时 `JSON.stringify` **直接省略这个键**。
    // Dart 的 `jsonEncode` 会把 null 写成 `"appVersion": null` ⇒ 显式省略，保持形状一致。
    if (appVersion != null) 'appVersion': appVersion,
    'cards': cards.map(cardToJson).toList(),
    'categories': categories.map((c) => c.toJson()).toList(),
    'locations': locations.map((l) => l.toJson()).toList(),
    'aliases': aliases.map((a) => a.toJson()).toList(),
    'settings': settings,
    'media': (media ?? const <MediaEntryMeta>[]).map((m) => m.toJson()).toList(),
    // 没带 Key 就**完全不写这个键** —— 老包与「关掉开关导出的包」形状一致，
    // 导入侧永远能靠 `apiKeys == null` 分辨「没带」。
    if (apiKeys != null) 'apiKeys': apiKeys,
  };
}

/// 卡片 → manifest 里的 JSON 对象。
///
/// TS 的 `MemoryCard` 就是普通对象，`JSON.stringify` 直接产出这些 camelCase 键 ⇒
/// 这里逐字段列出，**键名/顺序都与 TS 的对象字面量一致**（顺序不影响解析，但便于比对）。
Map<String, Object?> cardToJson(MemoryCard c) => <String, Object?>{
  'id': c.id,
  'status': c.status.wire,
  'needsOrganize': c.needsOrganize,
  'categoryId': c.categoryId,
  'entity': c.entity,
  'pathIds': c.pathIds,
  'pathNames': c.pathNames,
  'steps': c.steps?.map((s) => s.toJson()).toList(),
  'transcript': c.transcript,
  'desc': c.desc,
  'images': c.images,
  'audioPath': c.audioPath,
  'visionAnalyzed': c.visionAnalyzed,
  'tags': c.tags,
  'confidence': c.confidence,
  'ask': c.ask,
  'pathSuggestion': c.pathSuggestion,
  'pathMatched': c.pathMatched,
  'source': c.source.wire,
  'retryCount': c.retryCount,
  'nextRetryAt': c.nextRetryAt,
  'lastError': c.lastError,
  'createdAt': c.createdAt,
  'updatedAt': c.updatedAt,
};

MemoryCard cardFromJson(Map<String, Object?> json) => MemoryCard(
  id: (json['id'] ?? '').toString(),
  status: CardStatus.fromWire((json['status'] ?? '').toString()),
  needsOrganize: json['needsOrganize'] == true,
  categoryId: json['categoryId'] as String?,
  entity: json['entity'] as String?,
  pathIds: _strings(json['pathIds']),
  pathNames: json['pathNames'] as String?,
  steps: _steps(json['steps']),
  transcript: json['transcript'] as String?,
  desc: json['desc'] as String?,
  images: _strings(json['images']),
  audioPath: json['audioPath'] as String?,
  visionAnalyzed: json['visionAnalyzed'] as bool?,
  tags: _strings(json['tags']),
  confidence: (json['confidence'] as num?)?.toDouble(),
  ask: json['ask'] as String?,
  pathSuggestion: json['pathSuggestion'] as String?,
  pathMatched: json['pathMatched'] as bool?,
  source: SourceKind.fromWire(json['source']),
  retryCount: (json['retryCount'] as num?)?.toInt() ?? 0,
  nextRetryAt: json['nextRetryAt'] as String?,
  lastError: json['lastError'] as String?,
  createdAt: (json['createdAt'] ?? '').toString(),
  updatedAt: (json['updatedAt'] ?? '').toString(),
);

List<T> _listOf<T>(Object? raw, T Function(Map<String, Object?>) fromJson) {
  if (raw is! List) return <T>[];
  return raw
      .whereType<Map>()
      .map((m) => fromJson(m.cast<String, Object?>()))
      .toList();
}

List<String>? _strings(Object? raw) {
  if (raw is! List) return null;
  return raw.whereType<String>().toList();
}

List<StepItem>? _steps(Object? raw) {
  if (raw is! List) return null;
  return raw
      .whereType<Map>()
      .map((m) => StepItem.fromJson(m.cast<String, Object?>()))
      .toList();
}

/// 导出结果报告。字段名与 TS 的 `ExportReport` 一致（界面直接拿来显示）。
final class ExportReport {
  const ExportReport({
    required this.cards,
    required this.categories,
    required this.locations,
    required this.aliases,
    required this.mediaTotal,
    required this.mediaWritten,
    required this.mediaMissing,
    required this.bytes,
  });

  final int cards;
  final int categories;
  final int locations;
  final int aliases;
  final int mediaTotal;
  final int mediaWritten;

  /// DB 里引用了但磁盘上已不存在的媒体（**不阻断导出**，列出来让人知道）。
  final List<String> mediaMissing;

  /// 整包字节数（**含 7 字节容器头**）。
  final int bytes;
}

final class BackupConflict {
  const BackupConflict({
    required this.kind,
    required this.importedId,
    required this.localId,
    required this.name,
  });

  /// `'category'` 或 `'location'`。
  final String kind;

  final String importedId;
  final String localId;
  final String name;
}

/// 导入结果报告。
final class ImportReport {
  const ImportReport({
    required this.cardsInserted,
    required this.cardsUpdated,
    required this.cardsKeptLocal,
    required this.categoriesInserted,
    required this.categoriesKeptLocal,
    required this.locationsInserted,
    required this.locationsKeptLocal,
    required this.aliasesInserted,
    required this.settingsWritten,
    required this.settingsKeptLocal,
    required this.mediaWritten,
    required this.mediaOverwritten,
    required this.remappedCategoryRefs,
    required this.remappedLocationRefs,
    required this.droppedRefs,
    required this.conflicts,
  });

  final int cardsInserted;
  final int cardsUpdated;

  /// 本地同 id 更新更新，或本地更新更新（`updated_at` 新者胜）。
  final int cardsKeptLocal;

  final int categoriesInserted;
  final int categoriesKeptLocal;
  final int locationsInserted;
  final int locationsKeptLocal;
  final int aliasesInserted;
  final int settingsWritten;
  final int settingsKeptLocal;
  final int mediaWritten;

  /// 本地已有同路径媒体（按设计「媒体按相对路径覆盖」，这里只统计覆盖次数）。
  final int mediaOverwritten;

  /// 卡片引用的 category/location 在本地不存在，按名字重映射回本地 id 的次数。
  final int remappedCategoryRefs;
  final int remappedLocationRefs;

  /// 重映射也失败、只能置空的外键引用次数。
  final int droppedRefs;

  final List<BackupConflict> conflicts;

  /// 与 [mergeReport] 配套：只替换媒体计数，其余整份照搬。
  ImportReport withMedia({required int mediaWritten, required int mediaOverwritten}) =>
      ImportReport(
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
        mediaWritten: mediaWritten,
        mediaOverwritten: mediaOverwritten,
        remappedCategoryRefs: remappedCategoryRefs,
        remappedLocationRefs: remappedLocationRefs,
        droppedRefs: droppedRefs,
        conflicts: conflicts,
      );
}
