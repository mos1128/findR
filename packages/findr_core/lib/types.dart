/// 领域类型 —— 逐字对应 `packages/core/src/types.ts`（81 行）。
///
/// 相对 TS 的三处收紧，都写在下面对应位置的注释里：
///
/// 1. **字符串联合类型改成 enum**（`'pending_transcript' | ...` ⇒ [CardStatus]），
///    落库与进备份包一律走 `.wire` —— 那些字面值是格式的一部分，改不得；
/// 2. `source` 是唯一没有 `NOT NULL` 的枚举列 ⇒ 读出空值/怪值时**降级为 text 而不是抛**；
/// 3. [MemoryCard.copyWith] 用哨兵区分「不改这一列」与「把这一列改成 null」
///    （TS 的 `{ ...card, categoryId: null }` 直接表达得了，Dart 的可空形参不行）。
library;

/// 区分「没传这个参数」与「显式传了 null」。
///
/// 只在同库内使用：调用方永远不需要写出它，[CardPatch] / [MemoryCard.copyWith]
/// 的形参默认值会替调用方填上。
const Object unset = _Unset();

final class _Unset {
  const _Unset();
}

/// 卡片生命周期。
///
/// TS 侧是字符串联合类型，运行期就是裸字符串；这里用 enum 换编译期检查。
enum CardStatus {
  pendingTranscript('pending_transcript'),
  pending('pending'),
  active('active'),
  archived('archived');

  const CardStatus(this.wire);

  /// 落库 / 进备份包时用的字面值。`cards.status` 上有 CHECK 约束 —— **这就是格式**。
  final String wire;

  /// 未知值**直接抛**：`status` 是 `NOT NULL` + CHECK 双重约束，读出来是别的东西说明数据已经坏了。
  /// 宁可在读的那一刻炸，也别把一个来路不明的状态一路带到界面上去。
  static CardStatus fromWire(String value) {
    for (final status in values) {
      if (status.wire == value) return status;
    }
    throw ArgumentError.value(value, 'value', '未知的卡片状态');
  }
}

/// 卡片来源（照片 / 语音 / 打字）。
enum SourceKind {
  photo('photo'),
  voice('voice'),
  text('text');

  const SourceKind(this.wire);

  final String wire;

  /// 与 [CardStatus.fromWire] 不同，这里**回退而不是抛**：
  ///
  /// `cards.source` 只有 CHECK 没有 `NOT NULL`，而 SQLite 的 CHECK 对 NULL 求值为 NULL（放行），
  /// 所以空值是真可能的（老备份包、迁移中间态）。TS 那边会把这个 null 原样带到下游
  /// （表现为「既不是 voice 也不是 photo」）；这里显式落到 [text] —— 效果相同，但类型是干净的。
  static SourceKind fromWire(Object? value) {
    for (final kind in values) {
      if (kind.wire == value) return kind;
    }
    return SourceKind.text;
  }
}

/// `steps` 列里的一项（JSON `{text, done}`）。
final class StepItem {
  const StepItem({required this.text, required this.done});

  final String text;
  final bool done;

  /// 逐项构造而非 `parseJsonArray<StepItem>`：TS 那边是直接强转（元素是什么就当什么），
  /// 这里把「字段缺失/类型不对」收成默认值，坏元素不至于让整张卡片读不出来。
  factory StepItem.fromJson(Map<String, Object?> json) =>
      StepItem(text: (json['text'] ?? '').toString(), done: json['done'] == true);

  Map<String, Object?> toJson() => <String, Object?>{'text': text, 'done': done};

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is StepItem && other.text == text && other.done == done);

  @override
  int get hashCode => Object.hash(text, done);

  @override
  String toString() => 'StepItem($text, $done)';
}

/// 一条记忆卡片。
///
/// 关于「卡片长什么样」，这里刻意**只有 `categoryId` 一个组织维度**：
/// 早期版本还有 `structureType`（item/todo/procedure）与三个业务状态，用来决定字段必填性和
/// 卡片强调色。真机验证后确认这套东西对检索零影响、又逼着用户理解一套模型自己的概念，
/// 已于 2026-09-18 整体移除（见 `db/schema.dart` 的 v2 迁移）。
///
/// 代价与替代：原来「物品必须有位置」靠 `structureType === 'item'` 判定，现在改成**由内容驱动**
/// —— 模型在内容确实提到存放位置时才填 `path`，确实是一串步骤时才填 `steps`，
/// 缺关键信息则由 `ask` 追问。
final class MemoryCard {
  const MemoryCard({
    required this.id,
    required this.status,
    required this.needsOrganize,
    required this.categoryId,
    required this.entity,
    required this.pathIds,
    required this.pathNames,
    required this.steps,
    required this.transcript,
    required this.desc,
    required this.images,
    required this.audioPath,
    required this.visionAnalyzed,
    required this.tags,
    required this.confidence,
    required this.ask,
    required this.pathSuggestion,
    required this.pathMatched,
    required this.source,
    required this.retryCount,
    required this.nextRetryAt,
    required this.lastError,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final CardStatus status;
  final bool needsOrganize;
  final String? categoryId;
  final String? entity;
  final List<String>? pathIds;
  final String? pathNames;
  final List<StepItem>? steps;
  final String? transcript;
  final String? desc;
  final List<String>? images;
  final String? audioPath;
  final bool? visionAnalyzed;
  final List<String>? tags;
  final double? confidence;

  /// P1 补问文案；非空时记忆流展示补问入口，用户编辑后清空（需求 5.1「最多一次」）。
  final String? ask;

  /// 位置失配时模型给出的完整路径猜测，供用户点选或新建。
  final String? pathSuggestion;

  /// 本次 path 是否命中已有位置树（测试计划指标依据）。
  final bool? pathMatched;

  final SourceKind source;
  final int retryCount;
  final String? nextRetryAt;
  final String? lastError;
  final String createdAt;
  final String updatedAt;

  /// 浅拷贝 + 覆盖若干列。**凡是要「显式置 null」的列必须传 `null`**，
  /// 不传就是保持原值 —— 这是 TS 的 `{ ...card, categoryId: null }` 在 Dart 里的等价物
  /// （`backup/manifest.ts` 靠它清掉导入后已不存在的外键引用）。
  MemoryCard copyWith({
    String? id,
    CardStatus? status,
    bool? needsOrganize,
    Object? categoryId = unset,
    Object? entity = unset,
    Object? pathIds = unset,
    Object? pathNames = unset,
    Object? steps = unset,
    Object? transcript = unset,
    Object? desc = unset,
    Object? images = unset,
    Object? audioPath = unset,
    Object? visionAnalyzed = unset,
    Object? tags = unset,
    Object? confidence = unset,
    Object? ask = unset,
    Object? pathSuggestion = unset,
    Object? pathMatched = unset,
    SourceKind? source,
    int? retryCount,
    Object? nextRetryAt = unset,
    Object? lastError = unset,
    String? createdAt,
    String? updatedAt,
  }) => MemoryCard(
    id: id ?? this.id,
    status: status ?? this.status,
    needsOrganize: needsOrganize ?? this.needsOrganize,
    categoryId: identical(categoryId, unset) ? this.categoryId : categoryId as String?,
    entity: identical(entity, unset) ? this.entity : entity as String?,
    pathIds: identical(pathIds, unset) ? this.pathIds : pathIds as List<String>?,
    pathNames: identical(pathNames, unset) ? this.pathNames : pathNames as String?,
    steps: identical(steps, unset) ? this.steps : steps as List<StepItem>?,
    transcript: identical(transcript, unset) ? this.transcript : transcript as String?,
    desc: identical(desc, unset) ? this.desc : desc as String?,
    images: identical(images, unset) ? this.images : images as List<String>?,
    audioPath: identical(audioPath, unset) ? this.audioPath : audioPath as String?,
    visionAnalyzed: identical(visionAnalyzed, unset)
        ? this.visionAnalyzed
        : visionAnalyzed as bool?,
    tags: identical(tags, unset) ? this.tags : tags as List<String>?,
    confidence: identical(confidence, unset) ? this.confidence : confidence as double?,
    ask: identical(ask, unset) ? this.ask : ask as String?,
    pathSuggestion: identical(pathSuggestion, unset)
        ? this.pathSuggestion
        : pathSuggestion as String?,
    pathMatched: identical(pathMatched, unset) ? this.pathMatched : pathMatched as bool?,
    source: source ?? this.source,
    retryCount: retryCount ?? this.retryCount,
    nextRetryAt: identical(nextRetryAt, unset) ? this.nextRetryAt : nextRetryAt as String?,
    lastError: identical(lastError, unset) ? this.lastError : lastError as String?,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

/// 分类：用户唯一的组织桶，也是 P1 自动路由的目标池。
///
/// 以前每个分类还绑一个 `structureType` 来推导卡片形状，现已随 v2 迁移去掉 ——
/// 分类就是分类，卡片是「东西 / 待办 / 流程」由内容自己决定。
final class Category {
  const Category({
    required this.id,
    required this.name,
    required this.emoji,
    required this.description,
    required this.sort,
    required this.isPreset,
  });

  final String id;
  final String name;
  final String? emoji;
  final String? description;
  final int sort;
  final bool isPreset;
}

/// 位置树的一个节点。`parentId == null` 即根。
final class LocationNode {
  const LocationNode({
    required this.id,
    required this.parentId,
    required this.name,
    required this.sort,
  });

  final String id;
  final String? parentId;
  final String name;
  final int sort;
}

/// 别名表的一行。
///
/// 目前 core 内部只用 SQL 直接读写别名（`expandTermsByAliases` / `findLocationIdUnder`），
/// 这个类型是给上层与测试用的形状，与 TS 的 `AliasEntry` 一致。
final class AliasEntry {
  const AliasEntry({
    required this.id,
    required this.kind,
    required this.name,
    required this.cardId,
    required this.locationId,
  });

  final String id;

  /// 与列上的 CHECK 约束一致：`'entity' | 'location'`。
  final String kind;
  final String name;
  final String? cardId;
  final String? locationId;
}
