/// 模型输出的数据形状。
///
/// ⚠️ **本文件目前只有形状，没有校验。**
///
/// 每个字段都兜了默认值：字段缺失、类型不对、枚举值陌生，
/// 一律**落到默认值**而不是让整次解析失败（模型输出不稳定，这是刻意的容错设计）。
/// 校验函数不引第三方 schema 库，全部手写。
///
/// 所以此刻这里只定义「一份已经可信的 P2 输出长什么样」，供 `search/builder.dart` 消费。
/// 默认值写在构造函数里，与校验层的兜底取值一致 —— 两处必须同步改。
library;

/// 检索走哪条路（需求 5.3）。
///
/// - [locate] 定位题：用户知道自己要什么，本地字面检索能答（「我护照放哪了」）
/// - [advise] 推理题：用户给一个情景问「需要什么」，字面检索**必然 0 条** ——
///   因为「护照」这两个字永远不会出现在「出国玩该带什么」里，答案要靠常识把情景与库存连起来
///   （见 `search/advise.dart`）
enum SearchMode {
  locate('locate'),
  advise('advise');

  const SearchMode(this.wire);
  final String wire;
}

/// P2 对用户意图的粗分类。
enum P2Intent {
  findItem('find_item'),
  listTodo('list_todo'),
  recallSteps('recall_steps'),
  unknown('unknown');

  const P2Intent(this.wire);
  final String wire;
}

/// 多个关键词之间怎么连。
enum MatchMode {
  any('any'),
  all('all');

  const MatchMode(this.wire);
  final String wire;
}

/// 时间范围提示。
enum TimeHint {
  recent('recent'),
  thisWeek('this_week'),
  thisMonth('this_month'),
  thisYear('this_year');

  const TimeHint(this.wire);
  final String wire;
}

/// 检索规划（P2 的输出）。
///
/// 各字段的缺省值：
/// `mode` ⇒ locate、`intent` ⇒ unknown、数组 ⇒ 空、`match_mode` ⇒ any。
/// **`intent` 缺省成 unknown 很关键** —— 模型不认得这个字段时会退回纯字面检索，不会更糟。
final class P2Output {
  const P2Output({
    this.mode = SearchMode.locate,
    this.intent = P2Intent.unknown,
    this.keywords = const <String>[],
    this.synonyms = const <String>[],
    this.category,
    this.pathPrefix,
    this.timeHint,
    this.matchMode = MatchMode.any,
    this.scenario,
    this.aspects = const <String>[],
  });

  final SearchMode mode;
  final P2Intent intent;
  final List<String> keywords;
  final List<String> synonyms;
  final String? category;
  final List<String>? pathPrefix;
  final TimeHint? timeHint;
  final MatchMode matchMode;

  /// 仅 advise：一句话情景，供裁决时锁定判断范围（如「出国旅游」）。
  final String? scenario;

  /// 仅 advise：该情景通常需要的**类别**（不是具体物品名），用于给裁决提供方向。
  final List<String> aspects;

  /// 只换 [synonyms]，其余原样。
  ///
  /// 别名扩展后的词表会覆盖这里的 `synonyms`。
  /// **刻意不做通用的 `copyWith`**：这里有一半字段可空，通用版得靠哨兵区分「不改」
  /// 与「改成 null」，而本场景只会改这一个非空字段 —— 多出来的灵活性只会多一处误用面。
  P2Output withSynonyms(List<String> synonyms) => P2Output(
    mode: mode,
    intent: intent,
    keywords: keywords,
    synonyms: synonyms,
    category: category,
    pathPrefix: pathPrefix,
    timeHint: timeHint,
    matchMode: matchMode,
    scenario: scenario,
    aspects: aspects,
  );
}

/// P1（录入整理）的输出。
///
/// 各字段的**缺省值就是校验层的落默认值**（见 `parse/schema.dart`）：
/// 字符串 ⇒ 空串、数组 ⇒ 空、`category`/`path` ⇒ null。
///
/// ⚠️ 两个字段**不做兜底**（`path_matched` / `path_suggestion`）：类型不对会让
/// **整次解析失败**，而不是落默认值。这是有意保留的行为，别"顺手"补上默认值。
final class P1Output {
  const P1Output({
    this.category,
    this.entity = '',
    this.aliases = const <String>[],
    this.path,
    this.pathMatched,
    this.pathSuggestion,
    this.steps = const <String>[],
    this.desc = '',
    this.tags = const <String>[],
    this.confidence,
    this.missing = const <String>[],
    this.ask = '',
  });

  /// 必须来自已有分类，判定不出则 null。
  final String? category;

  final String entity;

  /// 别称 / 简称，用于日后检索（最多 5 个）。
  final List<String> aliases;

  /// 三级路径（房间 / 家具 / 容器）；内容没有存放位置时是 null。
  final List<String>? path;

  /// 本次 path 是否命中已有位置树。
  final bool? pathMatched;

  /// 位置失配时给出的完整路径猜测，供用户确认。
  final String? pathSuggestion;

  /// 有序步骤（纯文本）。
  final List<String> steps;

  final String desc;
  final List<String> tags;

  /// 模型自评置信度，0~1。
  final double? confidence;

  /// 缺失 / 不确定的字段名。
  final List<String> missing;

  /// 需要向用户补问的一句话；不追问时是空串。
  final String ask;
}

/// 裁决里「模型指向某张卡」的一次引用。
///
/// 模型可以只回 id 字符串，也可以回 `{id, why}`；两种都收 ——
/// 让「结构更完整」不成为一次解析失败的理由（[why] 缺省为空串）。
final class AdviceRef {
  const AdviceRef({required this.id, this.why = ''});

  final String id;
  final String why;
}

/// P4（推理题裁决）的输出。
///
/// 三档而不是二档：「必需 / 看情况」分开，是为了让「插线板」这类边界项能诚实表达成
/// 「看情况，取决于目的地插座标准」。二分类会逼模型二选一 —— 要么误删对的那条，
/// 要么为了保险全留下、退回成噪音。
final class P4Output {
  const P4Output({
    this.picks = const <AdviceRef>[],
    this.maybe = const <AdviceRef>[],
    this.missing = const <String>[],
    this.answer = '',
  });

  /// 必需：这个情景下没有它不行。
  final List<AdviceRef> picks;

  /// 看情况：可能要用，理由里必须写清取决于什么。
  final List<AdviceRef> maybe;

  /// 库里没有、但这个情景确实需要的东西（助手的义务：说「你没有的」）。
  final List<String> missing;

  final String answer;
}

/// P3（L2 答案组织）的输出。
final class P3Output {
  const P3Output({this.answer = '', this.hitIds = const <String>[], this.suggest = ''});

  final String answer;

  /// 用到的卡片 id —— 只保留真的在候选里的，模型编的一律丢（见 `search/answer.dart`）。
  final List<String> hitIds;

  final String suggest;
}
