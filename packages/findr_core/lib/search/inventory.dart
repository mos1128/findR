/// 库存清单与相关性打分 —— 逐字对应 `packages/core/src/search/inventory.ts`（190 行）。
///
/// 这一层回答的是「用户库里有什么」，供推理题（advise）逐条裁决。
/// 为什么必须有它：推理题的答案**不在库里**（「出国 → 护照」是世界知识），
/// 而模型从始至终看不到库存 ⇒ 它只能答「没找到」。这份清单就是补上那个缺失的输入。
///
/// **十七版起多了一步：先排序，再截断。** 原先直接用 `listCards`
/// （`ORDER BY created_at DESC`），把「最近的 200 条」当成了「最相关的 200 条」——
/// 而「最近」与「这个场合用不用得上」零相关。库一大，清单会被无关的新卡占满，
/// **去年记的护照正好被截在 200 之外**，那恰恰是这条链路存在的唯一理由。
///
/// 退化情形值得记一笔：若 [terms] 一个词都没碰上（例如 P2 判错了情景），所有分数都是 0
/// ⇒ 顺序退化成纯按时间倒序 = 改动前的行为，**不会比原来更差**。
/// 这也正是这里不需要「保底给最近 N 条」配额的原因。
library;

import 'dart:math' as math;

import '../db/driver.dart';
import '../db/repository.dart';
import '../types.dart';

/// 一次裁决最多列举多少条。
///
/// **这不是隐私限制**（是否外发由产品决定），而是「注意力与请求体都要有上界」：
/// 清单越长，模型越容易看漏真正相关的那几条，成本也线性上涨。
/// 超出时不是静默截断 —— [Inventory.text] 末尾会写明截断了，让模型有机会自己说「可能不全」。
const int inventoryLimit = 200;

/// 参与排序的候选池上界（**不是**外发上界）。
///
/// 排序必须发生在截断**之前**，所以候选池得比 [inventoryLimit] 宽得多。
/// 但「把整库读进内存」也要有个明确的界：真记到上万条时拿最近 2000 条参与排序，
/// 仍然比改动前的「最近 200 条」宽一个数量级。
const int inventoryPool = 2000;

const int _entityChars = 30;
const int _pathChars = 40;
const int _descChars = 60;

/// 交给 P4 的记忆库清单。
final class Inventory {
  const Inventory({
    required this.text,
    required this.total,
    required this.listed,
    required this.truncated,
    required this.cards,
  });

  /// 直接拼进 P4 user 消息的清单文本（已含截断说明）。
  final String text;

  /// 全库条数（不含 archived）。
  final int total;

  /// 实际列出的条数。
  final int listed;

  final bool truncated;

  /// 与 [text] 一一对应的卡片；**id 合法性只认这份集合**，防止模型指到没见过的卡。
  final List<MemoryCard> cards;
}

/// 换行会破坏「一行一条」的格式，压成空格。
String _oneLine(String? value, int max) {
  if (value == null || value.isEmpty) return '';
  final flat = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length > max ? '${flat.substring(0, max)}…' : flat;
}

String _lower(String? value) => (value ?? '').toLowerCase();

/// 一张卡参与打分的五组文本。
final class _CardFields {
  const _CardFields({
    required this.entity,
    required this.tags,
    required this.category,
    required this.path,
    required this.body,
  });

  final String entity;
  final String tags;
  final String category;
  final String path;
  final String body;

  /// 按 TS 的 `fields[key]` 取值。**键名就是格式的一部分**（见 [_fieldWeights]）。
  String operator [](String key) => switch (key) {
    'entity' => entity,
    'tags' => tags,
    'category' => category,
    'path' => path,
    _ => body,
  };
}

_CardFields _fieldsOf(MemoryCard card, String? categoryName) => _CardFields(
  entity: _lower(card.entity),
  tags: _lower((card.tags ?? const <String>[]).join(' ')),
  category: _lower(categoryName),
  path: _lower(card.pathNames),
  body: '${_lower(card.desc)} ${_lower(card.transcript)}',
);

/// 权重：同一个词命中主字段，比命中长描述更有信息量。
///
/// 「证件」出现在实体名或标签上，基本就是在说这张卡就是证件；
/// 出现在 desc 里则可能只是顺带提一句。
///
/// 用 Map 而不是数组：Dart 的 Map 保持插入顺序，与 TS 那个对象数组的字面量顺序一致。
const Map<String, int> _fieldWeights = <String, int>{
  'entity': 6,
  'tags': 4,
  'category': 3,
  'path': 2,
  'body': 1,
};

/// 把「这次在问什么」拆成能直接做子串比较的短词。
///
/// 中文没有词边界：`scenario` 与用户原句都是整句，整句拿去子串匹配必然零命中。
/// 所以分成两种处理：**短词原样用**（P2 给的 `aspects` 就是「证件」「洗漱用品」
/// 这类通用名词，命中率最高），**长句按 2 字滑窗切成 n-gram**
/// （「出国旅游需要带什么」切出「出国」「旅游」…，「旅游」才有机会真的碰到某张卡的 desc）。
///
/// ⚠️ 长度一律用 Dart 的 `String.length`（UTF-16 码元数）—— 与 JS 的 `String.length` 同口径。
List<String> relevanceTerms(List<String?> inputs) {
  final out = <String>{};
  final splitter = RegExp(r'[^\p{Script=Han}\p{L}\p{N}]+', unicode: true);
  for (final raw in inputs) {
    final text = (raw ?? '').toLowerCase().replaceAll(splitter, ' ').trim();
    if (text.isEmpty) continue;
    if (text.length <= 6) {
      out.add(text);
      continue;
    }
    for (final word in text.split(' ')) {
      if (word.isEmpty) continue;
      // 长词本身也留着：万一卡片里原样写过这句话呢（成本为零）
      out.add(word);
      for (var i = 0; i + 2 <= word.length; i++) {
        out.add(word.substring(i, i + 2));
      }
    }
  }
  return out.toList();
}

/// 相关性打分：只做本地子串统计，**不调模型、不碰网络**。
int _scoreCard(MemoryCard card, String? categoryName, List<String> terms) {
  final fields = _fieldsOf(card, categoryName);
  var score = 0;
  for (final term in terms) {
    // 4 字以上的词比 2 字滑窗更有信息量（「洗漱用品」命中 ≫「用品」命中）
    final boost = term.length >= 4 ? 2 : 1;
    for (final entry in _fieldWeights.entries) {
      if (fields[entry.key].contains(term)) score += entry.value * boost;
    }
  }
  return score;
}

/// 把记忆库压成一份「你有什么」的清单，供 P4 逐条裁决。
Inventory buildInventory(SqliteDriver db, {int? limit, List<String?>? terms}) {
  final effectiveLimit = math.max(0, limit ?? inventoryLimit);
  final total = countCards(db);
  final pool = total > 0
      ? listCards(db, ListCardsOptions(limit: math.min(total, inventoryPool)))
      : const <MemoryCard>[];
  final categoryName = <String, String>{
    for (final c in listCategories(db)) c.id: c.name,
  };
  final rankedTerms = relevanceTerms(terms ?? const <String?>[]);

  final List<MemoryCard> ranked;
  if (rankedTerms.isEmpty) {
    ranked = pool;
  } else {
    // 同分时保持 `listCards` 给出的「新的在前」；再补 id 兜底，
    // 让同分同时间的顺序**确定**下来，测试才不会偶发。
    final entries = pool
        .map(
          (card) => (
            card: card,
            score: _scoreCard(card, categoryName[card.categoryId ?? ''], rankedTerms),
          ),
        )
        .toList();
    entries.sort((a, b) {
      final byScore = b.score - a.score;
      if (byScore != 0) return byScore;
      // createdAt 是 ISO 串，字符串降序 = 时间倒序（新的在前）
      final byCreated = b.card.createdAt.compareTo(a.card.createdAt);
      if (byCreated != 0) return byCreated;
      return a.card.id.compareTo(b.card.id);
    });
    ranked = entries.map((e) => e.card).toList();
  }

  final cards = ranked.take(effectiveLimit).toList();

  const header = '序号 | id | 实体 | 分类 | 位置 | 简述';
  final rows = <String>[];
  for (var index = 0; index < cards.length; index++) {
    final card = cards[index];
    final entity = _oneLine(card.entity, _entityChars);
    final categoryId = card.categoryId;
    final category = (categoryId != null && categoryId.isNotEmpty)
        ? (categoryName[categoryId] ?? '未分类')
        : '未分类';
    final path = _oneLine(card.pathNames, _pathChars);
    // TS: `oneLine(desc) || oneLine(transcript) || '（无简述）'`
    final descBrief = _oneLine(card.desc, _descChars);
    final transcriptBrief = _oneLine(card.transcript, _descChars);
    final brief = descBrief.isNotEmpty
        ? descBrief
        : (transcriptBrief.isNotEmpty ? transcriptBrief : '（无简述）');

    rows.add(
      <String>[
        '${index + 1}',
        card.id,
        entity.isEmpty ? '（未命名）' : entity,
        category,
        path.isEmpty ? '未记录位置' : path,
        brief,
      ].join(' | '),
    );
  }

  final truncated = total > cards.length;
  final body = rows.isNotEmpty ? <String>[header, ...rows].join('\n') : '（记忆库还是空的）';
  final note = truncated
      ? '\n\n（全库共 $total 条，此处只列出'
            '${rankedTerms.isNotEmpty ? '与本次问题最相关的' : '最近的'} ${cards.length} 条'
            ' —— 可能不全。若清单里没有合适的东西，请在 answer 里说明可能还有未列出的条目。）'
      : '';

  return Inventory(
    text: body + note,
    total: total,
    listed: cards.length,
    truncated: truncated,
    cards: cards,
  );
}
