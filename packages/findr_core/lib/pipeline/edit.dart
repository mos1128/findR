/// 已入库卡片的再加工 —— 逐字对应 `packages/core/src/pipeline/edit.ts`（156 行）。
///
/// 四件事：补文字（没 ASR 时的兜底）、重新整理（解析失败的卡）、
/// 补分析图片（事后反悔）、以及编辑字段后重新生成 desc。
///
/// **它们都建立在 [runUnderstanding] 之上**，都不用先把卡片降级成草稿 ——
/// 这正是把理解步骤从 [advanceCard] 里抽出来的原因。
library;

import '../db/repository.dart';
import '../parse/model_json.dart';
import '../parse/outputs.dart';
import '../parse/schema.dart';
import '../prompts/render.dart';
import '../providers/types.dart';
import '../types.dart';
import 'capture.dart';

/// 把一次成功的理解结果落到卡片上（重新整理与补分析共用）。
void _applyUnderstanding(
  AdvanceDeps deps,
  String cardId,
  UnderstandingParsed result,
  DateTime now,
) {
  applyParseResult(deps.db, cardId, result.fields, now, idGen: deps.idGenerator);
  if (result.usedImages) setVisionAnalyzed(deps.db, cardId, true, now);
}

AdvanceResult _toAdvanceResult(
  AdvanceDeps deps,
  String cardId,
  UnderstandingResult result,
  DateTime now,
) {
  switch (result) {
    case UnderstandingPlain():
      return AdvanceResult(card: getCard(deps.db, cardId)!, outcome: AdvanceOutcome.plainCard);
    case UnderstandingParseFailed():
      return AdvanceResult(card: getCard(deps.db, cardId)!, outcome: AdvanceOutcome.needsOrganize);
    case UnderstandingError(:final error):
      // 失败时卡片保持原样：不能把一张已经可用的卡片降级成草稿
      return AdvanceResult(
        card: getCard(deps.db, cardId)!,
        outcome: AdvanceOutcome.retry,
        error: error,
      );
    case UnderstandingParsed():
      _applyUnderstanding(deps, cardId, result, now);
      return AdvanceResult(card: getCard(deps.db, cardId)!, outcome: AdvanceOutcome.activated);
  }
}

/// 补文字：把 `pending_transcript` 推进到 `pending` 并立刻跑一次理解。
/// 需求 3.2 的兜底路径 —— 没有 ASR 时用户随时可以自己补一句。
Future<AdvanceResult> submitTranscript(
  AdvanceDeps deps,
  String cardId,
  String text, {
  bool? vision,
}) async {
  setTranscript(deps.db, cardId, text, deps.clock());
  return advanceCard(deps, cardId, vision: vision);
}

/// 重新整理：针对解析失败（「待整理」）的卡片重跑一次理解。
///
/// 「待整理」不能只清标志就算修好 —— 清了之后卡片既没有 desc 也没有结构化字段。
/// 所以清标志必须与一次成功的重跑绑在一起。
Future<AdvanceResult> reorganizeCard(AdvanceDeps deps, String cardId) async {
  final clock = deps.clock;
  final card = getCard(deps.db, cardId);
  if (card == null) throw StateError('卡片不存在: $cardId');

  final result = await runUnderstanding(deps, card, vision: true);
  final now = clock();
  final out = _toAdvanceResult(deps, cardId, result, now);
  if (out.outcome == AdvanceOutcome.activated) clearNeedsOrganize(deps.db, cardId, now);
  return out;
}

/// 补分析图片（需求 5.1「关 + 事后反悔」）：对已入库卡片重跑一次带图的视觉理解，
/// 重新生成 desc 与结构化字段。
///
/// 与 [regenerateDesc] 的区别：这个会覆盖结构化字段，界面上要二次确认。
Future<AdvanceResult> reanalyzeCard(AdvanceDeps deps, String cardId) async {
  final clock = deps.clock;
  final card = getCard(deps.db, cardId);
  if (card == null) throw StateError('卡片不存在: $cardId');
  if (card.images == null || card.images!.isEmpty) {
    return AdvanceResult(
      card: card,
      outcome: AdvanceOutcome.skippedNotPending,
      error: '卡片没有图片可分析',
    );
  }

  final result = await runUnderstanding(deps, card, vision: true);
  return _toAdvanceResult(deps, cardId, result, clock());
}

final class RegenerateDescResult {
  const RegenerateDescResult({required this.card, required this.ok, this.error});

  final MemoryCard? card;
  final bool ok;
  final String? error;
}

/// 编辑结构化字段后重新生成 desc（需求四）。
///
/// **刻意不带图片**：这是一条便宜的纯文本调用，图里的信息早在第一次理解时就写进 desc 了。
/// **只取回 desc**，其余字段以用户编辑后的为准，绝不被模型覆盖。
Future<RegenerateDescResult> regenerateDesc(AdvanceDeps deps, String cardId) async {
  final clock = deps.clock;
  final card = getCard(deps.db, cardId);
  if (card == null) throw StateError('卡片不存在: $cardId');

  final system = buildP1System(
    categories: formatCategoriesForPrompt(listCategories(deps.db)),
    locations: formatLocationsForPrompt(listLocations(deps.db)),
    textOnly: TextOnlyMode.off,
  );

  try {
    final res = await deps.llm.chat(
      ChatRequest(
        system: system,
        parts: [TextPart(buildRegenerateDescUser(card))],
        temperature: 0.1,
      ),
      deps.cfg,
    );
    final parsed = parseModelJson(res.text, P1OutputSchema.tryParse);
    if (parsed is! ParseOk<P1Output>) {
      return RegenerateDescResult(
        card: getCard(deps.db, cardId),
        ok: false,
        error: (parsed as ParseFailure<P1Output>).error,
      );
    }

    updateCardFields(deps.db, cardId, CardPatch(desc: parsed.value.desc), clock());
    return RegenerateDescResult(card: getCard(deps.db, cardId), ok: true);
  } catch (e) {
    return RegenerateDescResult(card: getCard(deps.db, cardId), ok: false, error: e.toString());
  }
}
