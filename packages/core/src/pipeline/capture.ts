import type { SqliteDriver } from '../db/driver';
import {
  applyParseResult,
  ensurePath,
  getCard,
  insertCard,
  listCategories,
  listLocations,
  makeId,
  markNeedsOrganize,
  markPlainCard,
  markRetry,
  resolveCategoryId,
  setTranscript,
  setVisionAnalyzed,
} from '../db/repository';
import type { ParsedCardFields } from '../db/repository';
import { P1OutputSchema, parseModelJson } from '../parse';
import {
  buildP1System,
  buildP1User,
  formatCategoriesForPrompt,
  formatLocationsForPrompt,
} from '../prompts/render';
import type { MediaIO } from '../providers/media';
import type {
  ASRProviderAdapter,
  LLMProviderAdapter,
  Part,
  ProviderConfig,
} from '../providers/types';
import type { MemoryCard, SourceKind } from '../types';

/** 单卡送模型分析的图片上限。需求把「可配 N 张」列为非 MVP，这里是固定的请求体护栏 */
export const DEFAULT_MAX_ANALYZE_IMAGES = 6;

/** 音频容器：录音直出 m4a/AAC，不转码（技术设计二） */
export const AUDIO_MIME = 'audio/m4a';

export interface AdvanceDeps {
  db: SqliteDriver;
  llm: LLMProviderAdapter;
  cfg: ProviderConfig;
  /** 只有需要读图/读音频时才用到；纯文本链路可以不传 */
  media?: MediaIO;
  asr?: ASRProviderAdapter | null;
  asrCfg?: ProviderConfig | null;
  /** 主模型是否支持图片输入；false 时图片只作附件（需求 3.3） */
  visionSupported?: boolean;
  /** 模式 2 的 ASR 热词（房间名 + 常用物品名） */
  hotwords?: string[];
  now?: () => Date;
  idGen?: () => string;
  confirmThreshold?: number;
  maxAnalyzeImages?: number;
}

export interface CaptureInput {
  source: SourceKind;
  /** 已输入或已转写的文本；没有则为 null */
  text?: string | null;
  /** 已落盘的图片相对路径，顺序即拍摄/选择顺序 */
  images?: string[] | null;
  /** 已落盘的音频相对路径 */
  audio?: string | null;
}

/**
 * 落盘之后的第一步：插入草稿卡。纯数据库操作、不碰网络，
 * 因此录入界面可以立即拿到卡片渲染，素材也就永远不会因为网络问题而丢失。
 *
 * id 由调用方传入 —— 媒体路径里含 cardId，且要求「先写文件再插行」，
 * 所以 id 必须在平台层先于落盘生成。
 */
export function createDraft(
  deps: Pick<AdvanceDeps, 'db' | 'now'>,
  input: CaptureInput,
  opts: { id: string; now?: Date },
): MemoryCard {
  const now = opts.now ?? deps.now?.() ?? new Date();
  const ts = now.toISOString();
  const hasAudio = !!input.audio;
  const hasText = !!input.text && input.text.trim().length > 0;
  const images = input.images && input.images.length > 0 ? input.images : null;

  const draft: MemoryCard = {
    id: opts.id,
    // 有音频且无文本才等转写；已经打了字就直接进待解析（需求四「打字则跳过转写」）
    status: hasAudio && !hasText ? 'pending_transcript' : 'pending',
    needsConfirm: false,
    needsOrganize: false,
    structureType: null,
    categoryId: null,
    entity: null,
    pathIds: null,
    pathNames: null,
    itemStatus: null,
    todoStatus: null,
    procedureStatus: null,
    steps: null,
    relatedPerson: null,
    dueAt: null,
    cycle: null,
    transcript: hasText ? input.text!.trim() : null,
    desc: null,
    images,
    audioPath: input.audio ?? null,
    // 有图即视为「尚未成功分析过」；成功后由理解步骤置 1，无图恒为 null
    visionAnalyzed: images ? false : null,
    tags: null,
    confidence: null,
    ask: null,
    pathSuggestion: null,
    pathMatched: null,
    source: input.source,
    retryCount: 0,
    nextRetryAt: null,
    lastError: null,
    createdAt: ts,
    updatedAt: ts,
  };
  insertCard(deps.db, draft);
  return draft;
}

// ─────────────────────────────────────────────────────────────
// 理解步骤：一次模型调用，外加位置树的增量维护（会写 locations 表）。
// 抽出来是为了让「对已入库卡片重新理解」不必先把卡片降级成草稿。
// ─────────────────────────────────────────────────────────────

export type UnderstandingResult =
  | { kind: 'plain' }
  | { kind: 'parse-failed' }
  | { kind: 'error'; error: string }
  | {
      kind: 'parsed';
      fields: ParsedCardFields;
      needsConfirm: boolean;
      usedImages: boolean;
    };

export async function runUnderstanding(
  deps: AdvanceDeps,
  card: MemoryCard,
  opts: { vision: boolean },
): Promise<UnderstandingResult> {
  const images = card.images ?? [];
  const text = card.transcript;
  const visionSupported = deps.visionSupported ?? true;
  const maxImages = deps.maxAnalyzeImages ?? DEFAULT_MAX_ANALYZE_IMAGES;
  const imagesToSend = visionSupported && opts.vision ? images.slice(0, maxImages) : [];

  // 关掉图片分析 + 没有文字 ⇒ 没有任何可抽取的信息源。
  // 这里不能去调 P1：buildP1User 的兜底文案会与「不发图」自相矛盾，模型容易开始编。
  if (!text && imagesToSend.length === 0) return { kind: 'plain' };

  const parts: Part[] = [];
  if (imagesToSend.length > 0) {
    if (!deps.media) throw new Error('需要读取图片但未注入 MediaIO');
    for (const rel of imagesToSend) {
      const { base64, mime } = await deps.media.imageData(rel);
      parts.push({ type: 'image', mime, base64 });
    }
  }
  parts.push({ type: 'text', text: buildP1User(text) });

  // 两种「仅文本」变体的文案不同（需求 5.1 / prompt设计.md 一）
  const textOnly = !visionSupported
    ? ('unsupported' as const)
    : images.length > 0 && imagesToSend.length === 0
      ? ('off' as const)
      : undefined;

  const system = buildP1System({
    categories: formatCategoriesForPrompt(listCategories(deps.db)),
    locations: formatLocationsForPrompt(listLocations(deps.db)),
    textOnly,
  });
  const call = (extra: string) =>
    deps.llm.chat({ system: system + extra, parts, temperature: 0.1 }, deps.cfg);

  let parsed;
  try {
    const first = await call('');
    parsed = parseModelJson(first.text, P1OutputSchema);
    if (!parsed.ok) {
      const second = await call('\n\n注意：只输出一个合法 JSON 对象，不要任何多余文字。');
      parsed = parseModelJson(second.text, P1OutputSchema);
    }
  } catch (e) {
    return { kind: 'error', error: e instanceof Error ? e.message : String(e) };
  }
  if (!parsed.ok) return { kind: 'parse-failed' };

  const out = parsed.value;
  const categoryId = out.category ? resolveCategoryId(deps.db, out.category) : null;
  // item 的位置：匹配得到就复用，匹配不到就**新建**。位置树应当由解析结果增量长出来，
  // 而不是要求用户先去设置页手工建好房间再回来选（那等于把「模型会产出什么词」推给用户猜）
  const path =
    out.structure_type === 'item' && out.path
      ? ensurePath(deps.db, out.path, deps.idGen ?? makeId)
      : null;
  const needsConfirm =
    (out.confidence != null && out.confidence < (deps.confirmThreshold ?? 0.6)) ||
    categoryId === null ||
    // item 却没路径 ⇒ 得让用户补；路径里含新建层级 ⇒ 新位置对不对要用户过一眼
    (out.structure_type === 'item' && (!path || path.created.length > 0));

  return {
    kind: 'parsed',
    needsConfirm,
    usedImages: imagesToSend.length > 0,
    fields: {
      structureType: out.structure_type,
      categoryId,
      entity: out.entity,
      pathIds: path?.ids ?? null,
      pathNames: path?.namesStr ?? null,
      steps: out.steps.length > 0 ? out.steps.map((t) => ({ text: t, done: false })) : null,
      desc: out.desc,
      tags: out.tags,
      confidence: out.confidence ?? null,
      aliases: out.aliases,
      ask: out.ask || null,
      pathSuggestion: out.path_suggestion ?? null,
      // 以「本次真的新建过节点」为准，比模型自报可靠：新建过 ⇒ 没匹配上已有树
      pathMatched: path ? path.created.length === 0 : (out.path_matched ?? null),
    },
  };
}

export type AdvanceOutcome =
  | 'activated'
  | 'needs-organize'
  | 'plain-card'
  | 'retry'
  /** 没配 ASR：素材留着，等用户补文字或之后批量补转写，不算失败 */
  | 'skipped-no-asr'
  | 'skipped-not-pending';

export interface AdvanceResult {
  card: MemoryCard;
  outcome: AdvanceOutcome;
  error?: string;
}

export interface AdvanceOptions {
  /** 本次录入的图片分析开关；不传则由调用方（队列）决定 */
  vision?: boolean;
}

/**
 * 推进一张草稿卡：待转写 → 转写 → 理解 → 入库。
 * 所有失败都保持素材可重试，绝不静默丢弃（需求四、九）。
 */
export async function advanceCard(
  deps: AdvanceDeps,
  cardId: string,
  opts: AdvanceOptions = {},
): Promise<AdvanceResult> {
  const now = deps.now ?? (() => new Date());
  const reload = () => getCard(deps.db, cardId)!;

  let card = reload();
  if (card.status !== 'pending_transcript' && card.status !== 'pending') {
    return { card, outcome: 'skipped-not-pending' };
  }

  // ── 第一步：待转写 ────────────────────────────────────────
  if (card.status === 'pending_transcript') {
    if (!card.transcript) {
      if (!deps.asr || !deps.asrCfg || !card.audioPath) {
        return { card, outcome: 'skipped-no-asr' };
      }
      try {
        const { text } = await deps.asr.transcribe(
          {
            audio: { kind: 'file', rel: card.audioPath, mime: AUDIO_MIME },
            filename: 'audio.m4a',
            lang: 'zh',
            hotwords: deps.hotwords,
          },
          deps.asrCfg,
        );
        setTranscript(deps.db, cardId, text, now());
        card = reload();
      } catch (e) {
        const error = e instanceof Error ? e.message : String(e);
        markRetry(deps.db, cardId, error, now());
        return { card: reload(), outcome: 'retry', error };
      }
    } else {
      setTranscript(deps.db, cardId, card.transcript, now());
      card = reload();
    }
  }

  // ── 第二步：理解 ──────────────────────────────────────────
  let result: UnderstandingResult;
  try {
    result = await runUnderstanding(deps, card, { vision: opts.vision ?? true });
  } catch (e) {
    const error = e instanceof Error ? e.message : String(e);
    markRetry(deps.db, cardId, error, now());
    return { card: reload(), outcome: 'retry', error };
  }

  switch (result.kind) {
    case 'plain':
      markPlainCard(deps.db, cardId, now());
      return { card: reload(), outcome: 'plain-card' };
    case 'parse-failed':
      // 需求 3.4：重试 1 次仍失败 → 只保留原文与图片，标记「待整理」
      markNeedsOrganize(deps.db, cardId, now());
      return { card: reload(), outcome: 'needs-organize' };
    case 'error':
      markRetry(deps.db, cardId, result.error, now());
      return { card: reload(), outcome: 'retry', error: result.error };
    case 'parsed': {
      applyParseResult(deps.db, cardId, result.fields, result.needsConfirm, now(), deps.idGen ?? makeId);
      // 本次真的把图送出去了才算「已分析」，否则卡片要一直带着「未分析」角标
      if (result.usedImages) setVisionAnalyzed(deps.db, cardId, true, now());
      return { card: reload(), outcome: 'activated' };
    }
  }
}

/** 落盘 + 推进一次。界面若想先渲染草稿，请直接用 createDraft + advanceCard */
export async function ingestCapture(
  deps: AdvanceDeps,
  input: CaptureInput,
  opts: { id?: string; vision?: boolean } = {},
): Promise<MemoryCard> {
  const id = opts.id ?? (deps.idGen ?? makeId)();
  createDraft(deps, input, { id });
  const result = await advanceCard(deps, id, { vision: opts.vision });
  return result.card;
}
