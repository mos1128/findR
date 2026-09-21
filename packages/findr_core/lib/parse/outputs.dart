/// 模型输出的数据形状 —— 对应 `packages/core/src/parse/index.ts` 里的 `P2OutputSchema`。
///
/// ⚠️ **本文件目前只有形状，没有校验。**
///
/// TS 那边用 zod，每个字段都挂了 `.catch(...)`：字段缺失、类型不对、枚举值陌生，
/// 一律**落到默认值**而不是让整次解析失败（模型输出不稳定，这是刻意的容错设计）。
/// **Dart 没有 zod 等价物**（见 `Flutter迁移交接.md` §4），校验函数留到译 `parse/` 那一块时手写。
///
/// 所以此刻这里只定义「一份已经可信的 P2 输出长什么样」，供 `search/builder.dart` 消费。
/// 默认值写在构造函数里，与 zod 的 `.catch()` 取值一致 —— 等校验函数落地时直接复用。
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
/// 缺省值全部对齐 TS 里 zod 的 `.catch(...)`：
/// `mode` ⇒ locate、`intent` ⇒ unknown、数组 ⇒ 空、`match_mode` ⇒ any。
/// **`intent` 缺省成 unknown 很关键** —— 模型不认得这个字段时，行为与第十四版完全一致，不会更糟。
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
    this.normalizedQuery,
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

  final String? normalizedQuery;
}
