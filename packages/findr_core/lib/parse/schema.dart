/// 模型输出的**容错校验** —— 手写，不引第三方 schema 库。
///
/// 为什么要有这一层：模型的 JSON 永远不守规矩 —— 字段缺失、类型不对、枚举值陌生。
/// 给**每个字段**兜一个默认值，让单点错误只影响那一个字段，
/// 而不是让整次解析崩掉（崩掉就意味着用户白等一次调用）。
///
/// ⚠️ **兜底与否的边界必须精确**，因为「哪些字段失败会拖垮整次解析」是**行为**：
///
/// | 写法 | 失败时 |
/// |---|---|
/// | 落默认值 | 该字段落 `''`，**不影响别的字段** |
/// | 直接暴露失败 | **整次解析失败**（没有兜底接住） |
///
/// 具体到我们的四个 schema，**不做兜底的字段**是：
/// `P1Output.path_matched` / `.path_suggestion`、`P2Output.time_hint` / `.scenario` /
/// `.normalized_query`。也就是说模型把 `time_hint` 写成 `"yesterday"` 时，
/// 整条 P2 都作废、检索退回字面兜底 —— **别「顺手」补上默认值**。
///
/// 手写校验要的东西很有限：**取值 + 判型 + 落默认**，
/// 用 [tryParse] 返回 `null` 表达「整次失败」，其余用 `_caught` 逐字段兜。
library;

import 'outputs.dart';

/// **任何失败都落到 [fallback]**。
T _caught<T>(T Function() body, T fallback) {
  try {
    return body();
  } catch (_) {
    return fallback;
  }
}

/// 字段校验失败 —— 抛出去由 [tryParse] 的最外层接住。
Never _fail(String field, Object? value) =>
    throw FormatException('字段 $field 校验失败：$value');

String _string(Object? v, String field) {
  if (v is String) return v;
  _fail(field, v);
}

/// `.nullable()` 与 `.nullish()` 在这里取值路径相同（缺字段与显式 null 都取到 null），
/// **差别只在「有没有 `_caught` 包住」** —— 那正是上面表格里的行为分界。
String? _nullishString(Object? v, String field) {
  if (v == null || v is String) return v as String?;
  _fail(field, v);
}

bool? _nullishBool(Object? v, String field) {
  if (v == null || v is bool) return v as bool?;
  _fail(field, v);
}

List<String> _stringList(Object? v, String field) {
  if (v is! List) _fail(field, v);
  return <String>[for (final e in v) _string(e, field)];
}

List<String>? _nullishStringList(Object? v, String field) {
  if (v == null) return null;
  return _stringList(v, field);
}

/// `z.number().min(0).max(1)` —— 越界同样算失败（`confidence` 靠这条挡住 1.5 这种值）。
double? _nullishNumber01(Object? v, String field) {
  if (v == null) return null;
  if (v is! num) _fail(field, v);
  final d = v.toDouble();
  if (d < 0 || d > 1) _fail(field, v);
  return d;
}

/// 枚举取值：**陌生值算失败**（交给调用方决定是抛还是落默认）。
T _enumOf<T>(List<T> values, String Function(T) wire, Object? v, String field) {
  for (final x in values) {
    if (wire(x) == v) return x;
  }
  _fail(field, v);
}

T? _nullishEnumOf<T>(List<T> values, String Function(T) wire, Object? v, String field) {
  if (v == null) return null;
  // 显式写 <T>：否则返回位置的 `T?` 会把 `_enumOf` 的 T 推成 `T?`，
  // 于是 `String Function(T)` 就对不上 `String Function(T?)` 了（参数逆变）。
  return _enumOf<T>(values, wire, v, field);
}

/// P1 输出（录入整理）。
abstract final class P1OutputSchema {
  static P1Output? tryParse(Object? json) {
    if (json is! Map) return null;
    final m = json.cast<String, Object?>();
    try {
      return P1Output(
        category: _caught(() => _nullishString(m['category'], 'category'), null),
        entity: _caught(() => _string(m['entity'], 'entity'), ''),
        aliases: _caught(() => _stringList(m['aliases'], 'aliases'), const <String>[]),
        path: _caught(() => _nullishStringList(m['path'], 'path'), null),
        // 以下两个**没有 catch**：类型不对 ⇒ 整次解析失败（见文件头那张表）
        pathMatched: _nullishBool(m['path_matched'], 'path_matched'),
        pathSuggestion: _nullishString(m['path_suggestion'], 'path_suggestion'),
        steps: _caught(() => _stringList(m['steps'], 'steps'), const <String>[]),
        desc: _caught(() => _string(m['desc'], 'desc'), ''),
        tags: _caught(() => _stringList(m['tags'], 'tags'), const <String>[]),
        confidence: _caught(() => _nullishNumber01(m['confidence'], 'confidence'), null),
        missing: _caught(() => _stringList(m['missing'], 'missing'), const <String>[]),
        ask: _caught(() => _string(m['ask'], 'ask'), ''),
      );
    } catch (_) {
      return null;
    }
  }
}

/// P2 输出（检索规划）—— `search/` 那条链路的入口。
abstract final class P2OutputSchema {
  static P2Output? tryParse(Object? json) {
    if (json is! Map) return null;
    final m = json.cast<String, Object?>();
    try {
      return P2Output(
        mode: _caught(
          () => _enumOf(SearchMode.values, (x) => x.wire, m['mode'], 'mode'),
          SearchMode.locate,
        ),
        intent: _caught(
          () => _enumOf(P2Intent.values, (x) => x.wire, m['intent'], 'intent'),
          P2Intent.unknown,
        ),
        keywords: _caught(() => _stringList(m['keywords'], 'keywords'), const <String>[]),
        synonyms: _caught(() => _stringList(m['synonyms'], 'synonyms'), const <String>[]),
        category: _caught(() => _nullishString(m['category'], 'category'), null),
        pathPrefix: _caught(() => _nullishStringList(m['path_prefix'], 'path_prefix'), null),
        // 以下三个**不做兜底**（类型不对就整次失败）
        timeHint: _nullishEnumOf(TimeHint.values, (x) => x.wire, m['time_hint'], 'time_hint'),
        matchMode: _caught(
          () => _enumOf(MatchMode.values, (x) => x.wire, m['match_mode'], 'match_mode'),
          MatchMode.any,
        ),
        scenario: _nullishString(m['scenario'], 'scenario'),
        aspects: _caught(() => _stringList(m['aspects'], 'aspects'), const <String>[]),
        normalizedQuery: _nullishString(m['normalized_query'], 'normalized_query'),
      );
    } catch (_) {
      return null;
    }
  }
}

/// 裁决条目：**可以只回 id 字符串，也可以回 `{id, why}`** —— 两种都收。
AdviceRef _adviceRefOf(Object? v, String field) {
  if (v is String) return AdviceRef(id: v);
  if (v is Map) {
    final m = v.cast<String, Object?>();
    final id = _string(m['id'], '$field.id');
    return AdviceRef(
      id: id,
      // `z.string().catch('')`：why 缺失/非字符串都落空串，不影响整个条目
      why: _caught(() => _string(m['why'], '$field.why'), ''),
    );
  }
  _fail(field, v);
}

List<AdviceRef> _adviceRefList(Object? v, String field) {
  if (v is! List) _fail(field, v);
  return <AdviceRef>[for (final e in v) _adviceRefOf(e, field)];
}

/// P4 输出（推理题裁决）。
abstract final class P4OutputSchema {
  static P4Output? tryParse(Object? json) {
    if (json is! Map) return null;
    final m = json.cast<String, Object?>();
    try {
      return P4Output(
        // `.catch([])` 挂在**数组**上：只要有一个元素不合规，整档就变空数组。
        picks: _caught(() => _adviceRefList(m['picks'], 'picks'), const <AdviceRef>[]),
        maybe: _caught(() => _adviceRefList(m['maybe'], 'maybe'), const <AdviceRef>[]),
        missing: _caught(() => _stringList(m['missing'], 'missing'), const <String>[]),
        answer: _caught(() => _string(m['answer'], 'answer'), ''),
      );
    } catch (_) {
      return null;
    }
  }
}

/// P3 输出（L2 答案组织）。四个字段全有 catch ⇒ 这个 schema 不会整体失败。
abstract final class P3OutputSchema {
  static P3Output? tryParse(Object? json) {
    if (json is! Map) return null;
    final m = json.cast<String, Object?>();
    return P3Output(
      answer: _caught(() => _string(m['answer'], 'answer'), ''),
      hitIds: _caught(() => _stringList(m['hit_ids'], 'hit_ids'), const <String>[]),
      suggest: _caught(() => _string(m['suggest'], 'suggest'), ''),
    );
  }
}
