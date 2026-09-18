import {
  applyParseResult,
  clearNeedsOrganize,
  getCard,
  listCategories,
  listLocations,
  setTranscript,
  setVisionAnalyzed,
  updateCardFields,
} from '../db/repository';
import { P1OutputSchema, parseModelJson } from '../parse';
import {
  buildP1System,
  buildRegenerateDescUser,
  formatCategoriesForPrompt,
  formatLocationsForPrompt,
} from '../prompts/render';
import type { MemoryCard } from '../types';
import {
  advanceCard,
  runUnderstanding,
  type AdvanceDeps,
  type AdvanceResult,
  type UnderstandingResult,
} from './capture';

/** 把一次成功的理解结果落到卡片上（重新整理与补分析共用） */
function applyUnderstanding(
  deps: AdvanceDeps,
  cardId: string,
  result: Extract<UnderstandingResult, { kind: 'parsed' }>,
  now: Date,
): void {
  applyParseResult(deps.db, cardId, result.fields, result.needsConfirm, now, deps.idGen);
  if (result.usedImages) setVisionAnalyzed(deps.db, cardId, true, now);
}

function toAdvanceResult(
  deps: AdvanceDeps,
  cardId: string,
  result: UnderstandingResult,
  now: Date,
): AdvanceResult {
  const card = getCard(deps.db, cardId)!;
  switch (result.kind) {
    case 'plain':
      return { card, outcome: 'plain-card' };
    case 'parse-failed':
      return { card, outcome: 'needs-organize' };
    case 'error':
      // 失败时卡片保持原样：不能把一张已经可用的卡片降级成草稿
      return { card, outcome: 'retry', error: result.error };
    case 'parsed':
      applyUnderstanding(deps, cardId, result, now);
      return { card: getCard(deps.db, cardId)!, outcome: 'activated' };
  }
}

/**
 * 补文字：把 pending_transcript 推进到 pending 并立刻跑一次理解。
 * 需求 3.2 的兜底路径——没有 ASR 时用户随时可以自己补一句。
 */
export async function submitTranscript(
  deps: AdvanceDeps,
  cardId: string,
  text: string,
  opts: { vision?: boolean } = {},
): Promise<AdvanceResult> {
  const now = deps.now ?? (() => new Date());
  setTranscript(deps.db, cardId, text, now());
  return advanceCard(deps, cardId, opts);
}

/**
 * 重新整理：针对解析失败（「待整理」）的卡片重跑一次理解。
 *
 * 「待整理」不能只清标志就算修好——清了之后卡片既没有 desc 也没有结构化字段。
 * 所以清标志必须与一次成功的重跑绑在一起。
 */
export async function reorganizeCard(deps: AdvanceDeps, cardId: string): Promise<AdvanceResult> {
  const clock = deps.now ?? (() => new Date());
  const card = getCard(deps.db, cardId);
  if (!card) throw new Error(`卡片不存在: ${cardId}`);

  const result = await runUnderstanding(deps, card, { vision: true });
  const now = clock();
  const out = toAdvanceResult(deps, cardId, result, now);
  if (out.outcome === 'activated') clearNeedsOrganize(deps.db, cardId, now);
  return out;
}

/**
 * 补分析图片（需求 5.1「关 + 事后反悔」）：对已入库卡片重跑一次带图的视觉理解，
 * 重新生成 desc 与结构化字段。
 *
 * 与 regenerateDesc 的区别：这个会覆盖结构化字段，界面上要二次确认。
 */
export async function reanalyzeCard(deps: AdvanceDeps, cardId: string): Promise<AdvanceResult> {
  const clock = deps.now ?? (() => new Date());
  const card = getCard(deps.db, cardId);
  if (!card) throw new Error(`卡片不存在: ${cardId}`);
  if (!card.images || card.images.length === 0) {
    return { card, outcome: 'skipped-not-pending', error: '卡片没有图片可分析' };
  }

  const result = await runUnderstanding(deps, card, { vision: true });
  return toAdvanceResult(deps, cardId, result, clock());
}

export interface RegenerateDescResult {
  card: MemoryCard | undefined;
  ok: boolean;
  error?: string;
}

/**
 * 编辑结构化字段后重新生成 desc（需求四）。
 * 刻意不带图片：这是一条便宜的纯文本调用，图里的信息早在第一次理解时就写进 desc 了。
 * 只取回 desc，其余字段以用户编辑后的为准，绝不被模型覆盖。
 */
export async function regenerateDesc(
  deps: AdvanceDeps,
  cardId: string,
): Promise<RegenerateDescResult> {
  const now = deps.now ?? (() => new Date());
  const card = getCard(deps.db, cardId);
  if (!card) throw new Error(`卡片不存在: ${cardId}`);

  const system = buildP1System({
    categories: formatCategoriesForPrompt(listCategories(deps.db)),
    locations: formatLocationsForPrompt(listLocations(deps.db)),
    textOnly: 'off',
  });

  try {
    const res = await deps.llm.chat(
      {
        system,
        parts: [{ type: 'text', text: buildRegenerateDescUser(card) }],
        temperature: 0.1,
      },
      deps.cfg,
    );
    const parsed = parseModelJson(res.text, P1OutputSchema);
    if (!parsed.ok) return { card: getCard(deps.db, cardId), ok: false, error: parsed.error };

    updateCardFields(deps.db, cardId, { desc: parsed.value.desc }, now());
    return { card: getCard(deps.db, cardId), ok: true };
  } catch (e) {
    return {
      card: getCard(deps.db, cardId),
      ok: false,
      error: e instanceof Error ? e.message : String(e),
    };
  }
}
