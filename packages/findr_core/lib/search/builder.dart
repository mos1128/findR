/// 检索条件构造 —— 逐字对应 `packages/core/src/search/builder.ts`（186 行）。
///
/// 这一层只做一件事：把「P2 的检索规划」翻译成 `BuiltSearch`（一组能直接喂给 SQL 的条件）。
/// 它不碰数据库 —— 真正的执行在 `db/repository.dart` 的 `executeSearch` 里。
///
/// 三个容易被忽略但必须保留的设计（原文注释都在 TS 那边，这里只留要点）：
///
/// 1. **trigram 硬限制**：<3 字的词（「护照」「猫砂」）FTS 匹配不到，必须降级 LIKE
///    （见 [splitTerms]）。这不是优化，是正确性 —— 3 字以下是 trigram 的物理下限。
/// 2. **放宽顺序**（见 [relaxations]）：严格条件 0 命中时按「多容易误伤」逐级放宽，
///    但**绝不动 ftsExpr / likeTerms** —— 那是检索的语义核心，动了就变成另一个查询了。
/// 3. **兜底检索要切虚词**（见 [buildRawSearch]）：中文没有词边界，整句当一个 FTS 短语
///    必然 0 条。这是离线可用性的头号杀手。
library;

import '../parse/outputs.dart';
import '../types.dart';
import '../util/iso.dart';

/// 一次检索的全部条件。TS 里是个 interface，这里补一个 [copyWith] 给 [relaxations] 用。
final class BuiltSearch {
  const BuiltSearch({
    required this.ftsExpr,
    required this.likeTerms,
    required this.matchMode,
    required this.categoryId,
    required this.pathPrefixLike,
    required this.sinceIso,
    required this.limit,
  });

  /// 已拼好的 FTS5 查询表达式；没有 ≥3 字的词时为 null（走纯 LIKE）。
  final String? ftsExpr;

  /// <3 字的词，只能走 LIKE。
  final List<String> likeTerms;

  final MatchMode matchMode;
  final String? categoryId;

  /// 已转义的 `主卧/衣柜%` 形式（LIKE 前缀），调用方负责拼 `ESCAPE '\'`。
  final String? pathPrefixLike;

  final String? sinceIso;
  final int limit;

  /// 只放宽过滤条件与连接方式，**不动 [ftsExpr] / [likeTerms]**（见 [relaxations] 的说明）。
  BuiltSearch copyWith({
    Object? ftsExpr = unset,
    Object? likeTerms = unset,
    MatchMode? matchMode,
    Object? categoryId = unset,
    Object? pathPrefixLike = unset,
    Object? sinceIso = unset,
    int? limit,
  }) => BuiltSearch(
    ftsExpr: identical(ftsExpr, unset) ? this.ftsExpr : ftsExpr as String?,
    likeTerms: identical(likeTerms, unset) ? this.likeTerms : likeTerms as List<String>,
    matchMode: matchMode ?? this.matchMode,
    categoryId: identical(categoryId, unset) ? this.categoryId : categoryId as String?,
    pathPrefixLike: identical(pathPrefixLike, unset)
        ? this.pathPrefixLike
        : pathPrefixLike as String?,
    sinceIso: identical(sinceIso, unset) ? this.sinceIso : sinceIso as String?,
    limit: limit ?? this.limit,
  );
}

/// 把词包成 FTS5 短语（内部的 `"` 用 `""` 转义）。
String quoteFts(String term) => '"${term.replaceAll('"', '""')}"';

/// LIKE 模式里转义 `\` `%` `_`。**必须配 `ESCAPE '\'` 使用**，缺了它反斜杠会被当普通字符。
String escapeLike(String term) => term.replaceAllMapped(
  RegExp(r'[\\%_]'),
  (m) => '\\${m[0]}',
);

/// trigram 硬限制：<3 字的词 FTS 匹配不到，单独拎出来走 LIKE。
///
/// ⚠️ 长度用 Dart 的 `String.length`（UTF-16 码元数），**与 JS 的 `String.length` 同口径**；
/// 不要换成按字素簇计数的那套 API —— 两者对代理对（emoji 等）的答案不同，
/// 换了就会在「≥3 字走 MATCH」这条分界线上和 TS 版分歧。
({List<String> fts, List<String> like}) splitTerms(List<String> terms) {
  final clean = <String>[];
  for (final t in terms.map((t) => t.trim())) {
    if (t.isEmpty || clean.contains(t)) continue;
    clean.add(t);
  }
  return (
    fts: clean.where((t) => t.length >= 3).toList(),
    like: clean.where((t) => t.length < 3).toList(),
  );
}

const Map<TimeHint, int> _timeHintMs = <TimeHint, int>{
  TimeHint.recent: 3 * 86400000,
  TimeHint.thisWeek: 7 * 86400000,
  TimeHint.thisMonth: 30 * 86400000,
  TimeHint.thisYear: 365 * 86400000,
};

/// TS 的 `new Date(now.getTime() - ms[hint]).toISOString()` —— 注意 `now` 的时区无关紧要
/// （`getTime()` 是 epoch 毫秒），产出恒为 UTC 的 ISO 串。
String? _sinceOf(TimeHint? hint, DateTime now) {
  if (hint == null) return null;
  final delta = _timeHintMs[hint];
  if (delta == null) return null;
  return isoUtc(
    DateTime.fromMillisecondsSinceEpoch(now.millisecondsSinceEpoch - delta, isUtc: true),
  );
}

/// P2 结果 → SQL 输入；`intent == unknown` 或关键词为空时返回 null（**不盲查**，UI 提示换说法）。
BuiltSearch? buildSearch({
  required P2Output p2,
  required String? Function(String name) resolveCategoryId,
  DateTime? now,
}) {
  if (p2.intent == P2Intent.unknown || p2.keywords.isEmpty) return null;
  final split = splitTerms(<String>[...p2.keywords, ...p2.synonyms]);
  final ftsExpr = split.fts.isEmpty
      ? null
      : split.fts.map(quoteFts).join(p2.matchMode == MatchMode.all ? ' AND ' : ' OR ');
  final category = p2.category;
  // TS 写的是 `p2.category ? ... : null`，空字符串同样算没有 ⇒ 这里一并判掉
  final categoryId = (category != null && category.isNotEmpty)
      ? resolveCategoryId(category)
      : null;
  final prefix = p2.pathPrefix;
  final pathPrefixLike = (prefix != null && prefix.isNotEmpty)
      ? '${escapeLike(prefix.join('/'))}%'
      : null;
  return BuiltSearch(
    ftsExpr: ftsExpr,
    likeTerms: split.like,
    matchMode: p2.matchMode,
    categoryId: categoryId,
    pathPrefixLike: pathPrefixLike,
    sinceIso: _sinceOf(p2.timeHint, now ?? DateTime.now()),
    limit: 50,
  );
}

/// 严格条件 0 命中时，按「这个约束有多容易误伤」的顺序逐级放宽，返回**累积**的候选条件。
///
/// 为什么必须有这一层：这些约束是 P2 **顺手加上**的（`P2_RULES` 甚至鼓励它依意图推断分类），
/// 一旦猜错就把正确答案整批剔掉，而且是**静默**的 —— 用户只看到「0 条」，
/// 无从判断是说法问题还是卡片丢了。实测「国外出行需要准备哪些证件」这种问法，
/// 模型很容易判成「待买补货」（「需要准备」读着像待办），于是 `category` 过滤把
/// 「物品存取」里的护照卡排除掉 —— 而卡片标签里明明就写着「证件」。
///
/// 放宽顺序：
/// 1. 去掉 `category` —— 最容易被意图误推的分类，误伤面最大；
/// 2. 去掉 `path_prefix` 与 `time_hint` —— 同样是模型顺手加的硬过滤；
/// 3. `all` → `any` —— AND 变 OR（`all` 只在用户原话确实并列多个条件时才该用，猜错就全灭）。
List<BuiltSearch> relaxations(BuiltSearch s) {
  final out = <BuiltSearch>[];
  var cur = s;
  if (cur.categoryId != null) {
    cur = cur.copyWith(categoryId: null);
    out.add(cur);
  }
  if (cur.pathPrefixLike != null || cur.sinceIso != null) {
    cur = cur.copyWith(pathPrefixLike: null, sinceIso: null);
    out.add(cur);
  }
  if (cur.matchMode == MatchMode.all) {
    cur = cur.copyWith(matchMode: MatchMode.any);
    out.add(cur);
  }
  return out;
}

/// 兜底检索要丢弃的虚词 / 疑问词。
///
/// 中文没有词边界，只按标点切分的话整句会被当成一个长短语：「我的护照在哪」变成一个
/// 8 字 FTS 短语，而卡片里存的是「护照放在主卧抽屉」—— 连续子串对不上，必然 0 条。
/// 于是「离线也能搜」变成了「离线搜不到」。
///
/// 按这些词切开后剩下的是实词（「护照」），才可能命中卡片。
/// 只收多字词和少数绝对安全的单字；单字的「在 / 放 / 找」刻意不收 ——
/// 它们会切坏「现在」「放心」「寻找」这类正常词，得不偿失。
const List<String> _rawStopwords = <String>[
  '什么', '怎么', '为什么', '哪去了', '哪里', '哪个', '哪儿', '在哪',
  '放在', '放到', '收在', '请问', '帮我', '帮忙', '一下', '我的',
  '你的', '他的', '她的', '记得', '上次', '那个', '这个', '有没有',
  '没有', '了吗', '是不是', '的', '了', '吗', '呢', '吧', '啊',
];

/// 按停用词把一段文本切成实词片段；切不动就原样返回。
List<String> _cutByStopwords(String segment) {
  var parts = <String>[segment];
  for (final w in _rawStopwords) {
    if (!parts.any((p) => p.contains(w))) continue;
    final next = <String>[];
    for (final p in parts) {
      if (p.contains(w)) {
        next.addAll(p.split(w));
      } else {
        next.add(p);
      }
    }
    parts = next;
  }
  return parts.map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
}

/// 兜底路径：P2 失败 / 无网 / 未配模型时，原始 query 直查
/// （无同义词扩展、无分类位置时间约束）。
///
/// 切词分两步：**先按标点，再按虚词** —— 后者是为了让中文整句也能落到实词上。
BuiltSearch buildRawSearch(String query) {
  final segments = query
      .split(RegExp(r'''[\s，。？！,.?!、；;：:"'“”‘’()（）]+'''))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  final base = segments.isNotEmpty ? segments : <String>[query];
  final refined = base.expand(_cutByStopwords).toList();
  // 整句都是虚词（如「在哪」）时会切空，此时退回原串，宁可 0 条也别查空条件
  final terms = refined.isNotEmpty ? refined : base;

  final split = splitTerms(terms);
  return BuiltSearch(
    ftsExpr: split.fts.isEmpty ? null : split.fts.map(quoteFts).join(' OR '),
    likeTerms: split.like,
    matchMode: MatchMode.any,
    categoryId: null,
    pathPrefixLike: null,
    sinceIso: null,
    limit: 50,
  );
}
