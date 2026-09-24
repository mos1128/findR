/// L2 答案组织。
///
/// 把 L1 命中的 top-N 条目交给主模型组织成答案卡片。
///
/// 触发时机按需求 5.3：**本地无结果或用户手动触发**，不是每次搜索都跑——
/// 每次跑会白白多花一次模型调用，而 L1 命中的卡片列表本身往往就够用。
/// 片段为空时仍然值得调用：P3 的约束是「片段不足以回答时直接说没找到并说明缺什么线索」。
library;

import '../parse/model_json.dart';
import '../parse/outputs.dart';
import '../parse/schema.dart';
import '../prompts/render.dart';
import '../providers/types.dart';
import '../types.dart';

/// L2 只送命中片段，**永不发送全库**（需求 5.3 的硬约束）。
const int l2MaxSnippets = 8;

/// 单条片段里描述与原文各自的截断长度，给请求体一个上界。
const int _descChars = 240;
const int _transcriptChars = 160;

final class AnswerDeps {
  const AnswerDeps({required this.llm, required this.cfg});

  final LlmProviderAdapter llm;
  final ProviderConfig cfg;
}

final class AnswerResult {
  const AnswerResult({
    required this.ok,
    this.answer = '',
    this.hitIds = const <String>[],
    this.suggest = '',
    this.error,
    this.usage,
  });

  final bool ok;
  final String answer;

  /// 只保留真的在候选里的 id —— 模型编出来的 id 一律丢掉，否则高亮会指向不存在的卡。
  final List<String> hitIds;

  final String suggest;
  final String? error;
  final ChatUsage? usage;
}

String _clip(String? value, int max) {
  if (value == null || value.isEmpty) return '';
  final text = value.trim();
  return text.length > max ? '${text.substring(0, max)}…' : text;
}

/// 取前 [n] 个码元 —— **短于 [n] 时原样返回，不抛**。
String _head(String value, int n) => value.length > n ? value.substring(0, n) : value;

bool _has(String? value) => value != null && value.isNotEmpty;

/// 把命中卡片压成 P3 能吃的片段块。**id 必须带上**，`hit_ids` 要靠它对回来做高亮。
String formatSnippets(List<MemoryCard> cards, [int limit = l2MaxSnippets]) {
  if (cards.isEmpty) return '（没有命中任何片段）';
  final picked = cards.length > limit ? cards.sublist(0, limit) : cards;
  final blocks = <String>[];
  for (var index = 0; index < picked.length; index++) {
    final card = picked[index];
    final lines = <String>['[${index + 1}] id=${card.id}'];
    if (_has(card.pathNames)) lines.add('位置：${card.pathNames}');
    if (_has(card.entity)) lines.add('实体：${card.entity}');
    if (_has(card.desc)) lines.add('描述：${_clip(card.desc, _descChars)}');
    final transcript = _clip(card.transcript, _transcriptChars);
    // ⚠️ 比的是**截断后的 transcript** 与**原始的 desc**，两边不对称是有意的 ——
    // 别"顺手"改成两边都截断，那会改变重复判定的结果。
    if (transcript.isNotEmpty && transcript != card.desc) {
      lines.add('原文：$transcript');
    }
    lines.add('记录时间：${_head(card.createdAt, 10)}');
    blocks.add(lines.join('\n'));
  }
  return blocks.join('\n\n');
}

/// 把 L1 命中的卡片交给主模型组织答案。
Future<AnswerResult> answerFromCards(
  AnswerDeps deps,
  String query,
  List<MemoryCard> cards,
) async {
  try {
    final res = await deps.llm.chat(
      ChatRequest(
        system: buildP3System(),
        parts: <Part>[TextPart(buildP3Input(query, formatSnippets(cards)))],
        temperature: 0.1,
      ),
      deps.cfg,
    );
    final parsed = parseModelJson(res.text, P3OutputSchema.tryParse);
    // 用 switch 而不是 `is!` 再取属性：`ParseResult` 是 sealed 且只有两个子类，
    // 这样写既是穷尽的（以后加子类会编译报错），也不用依赖类型提升。
    final P3Output p3;
    switch (parsed) {
      case ParseOk<P3Output>(:final value):
        p3 = value;
      case ParseFailure<P3Output>(:final error):
        return AnswerResult(ok: false, error: error);
    }
    final known = <String>{for (final c in cards) c.id};
    return AnswerResult(
      ok: true,
      answer: p3.answer,
      hitIds: p3.hitIds.where(known.contains).toList(),
      suggest: p3.suggest,
      usage: res.usage,
    );
  } catch (e) {
    return AnswerResult(ok: false, error: e.toString());
  }
}
