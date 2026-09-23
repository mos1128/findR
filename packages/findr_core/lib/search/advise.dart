/// 推理题的裁决。
///
/// 与 L2（`answer.dart`）的区别是根本性的，**不能合并**：
///
/// - L2 的约束是「**不得补充片段之外的任何信息**」—— 它只能复述已找到的东西；
/// - 这里的约束恰恰相反，**必须用常识判断「那个场合用不用得上」**——
///   因为答案根本不在库里（「出国 → 护照」是世界知识，不是字面相似度）。
///
/// 把两件事塞进同一个 prompt，只会让两条路都变弱。
///
/// 三道防线保证它不会乱说：只能挑清单里存在的 id（编的一律丢）、
/// 拿不准的进 maybe 而不是被静默删掉、库里的缺口写进 missing 而不是假装没有。
library;

import '../parse/model_json.dart';
import '../parse/outputs.dart';
import '../parse/schema.dart';
import '../prompts/render.dart';
import '../providers/types.dart';
import '../types.dart';
import 'inventory.dart';

/// 裁决结果里的一条：卡片 + 模型给的一句话理由。
final class AdviceItem {
  const AdviceItem({required this.id, required this.card, required this.why});

  final String id;
  final MemoryCard card;

  /// 模型给的一句话理由（必需：为什么必需；看情况：取决于什么）。
  final String why;
}

/// 一次裁决的完整结果。
final class AdviceResult {
  const AdviceResult({
    required this.ok,
    this.picks = const <AdviceItem>[],
    this.maybe = const <AdviceItem>[],
    this.missing = const <String>[],
    this.answer = '',
    this.error,
  });

  final bool ok;

  /// 必需。
  final List<AdviceItem> picks;

  /// 看情况。
  final List<AdviceItem> maybe;

  /// 库里没有、但这个情景确实需要的东西。
  final List<String> missing;

  final String answer;

  final String? error;
}

final class AdviceDeps {
  const AdviceDeps({required this.llm, required this.cfg});

  final LlmProviderAdapter llm;
  final ProviderConfig cfg;
}

/// 把「情景 + 整个记忆库的清单」交给主模型逐条判相关性。
Future<AdviceResult> adviseFromInventory(
  AdviceDeps deps,
  String query,
  String scenario,
  Inventory inventory,
) async {
  try {
    final res = await deps.llm.chat(
      ChatRequest(
        system: buildP4System(),
        parts: <Part>[
          TextPart(buildP4Input(query, scenario, inventory.total, inventory.text)),
        ],
        temperature: 0.1,
      ),
      deps.cfg,
    );
    final parsed = parseModelJson(res.text, P4OutputSchema.tryParse);
    // 用 switch 而不是 `is!` 再取属性：`ParseResult` 是 sealed 且只有两个子类，
    // 这样写既是穷尽的（以后加子类会编译报错），也不用依赖类型提升。
    final P4Output p4;
    switch (parsed) {
      case ParseOk<P4Output>(:final value):
        p4 = value;
      case ParseFailure<P4Output>(:final error):
        return AdviceResult(ok: false, error: error);
    }

    final byId = <String, MemoryCard>{
      for (final c in inventory.cards) c.id: c,
    };

    List<AdviceItem> take(List<AdviceRef> refs) {
      final seen = <String>{};
      final taken = <AdviceItem>[];
      for (final ref in refs) {
        final card = byId[ref.id];
        // 模型编出来的 id、或重复出现的同一张卡，一律丢掉 —— 否则列表会指向不存在的卡
        if (card == null || seen.contains(card.id)) continue;
        seen.add(card.id);
        taken.add(AdviceItem(id: card.id, card: card, why: ref.why));
      }
      return taken;
    }

    final picks = take(p4.picks);
    final pickedIds = <String>{for (final p in picks) p.id};
    // 同一张卡同时进了两档时以 picks 为准，否则列表里会出现两张一样的卡
    final maybe = take(
      p4.maybe,
    ).where((m) => !pickedIds.contains(m.id)).toList();

    return AdviceResult(
      ok: true,
      picks: picks,
      maybe: maybe,
      missing: p4.missing.map((m) => m.trim()).where((m) => m.isNotEmpty).toList(),
      answer: p4.answer,
    );
  } catch (e) {
    return AdviceResult(ok: false, error: e.toString());
  }
}
