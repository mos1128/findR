import type { SqliteDriver } from '../db/driver';
import {
  applyParseResult,
  getCard,
  insertCard,
  listCategories,
  listLocations,
  makeId,
  markNeedsOrganize,
  markRetry,
  resolvePath,
} from '../db/repository';
import { P1OutputSchema, parseModelJson } from '../parse';
import {
  buildP1System,
  buildP1User,
  formatCategoriesForPrompt,
  formatLocationsForPrompt,
} from '../prompts/render';
import type { LLMProviderAdapter, ProviderConfig } from '../providers/types';
import type { MemoryCard } from '../types';

export interface IngestDeps {
  db: SqliteDriver;
  llm: LLMProviderAdapter;
  cfg: ProviderConfig;
  now?: () => Date;
  idGen?: () => string;
  /** 低于该置信度强制用户确认（需求 3.4） */
  confirmThreshold?: number;
}

/**
 * 纯文本录入主链路：先落盘 pending 草稿卡（素材永不丢）→ P1 解析 → 入库。
 * - 解析失败：重试 1 次（追加简化指令）→ 仍失败标记 needs_organize，仅保留原文
 * - 调用失败：保持 pending，retry_count + 1（由后续重试队列接管）
 */
export async function ingestText(
  deps: IngestDeps,
  input: { transcript: string },
): Promise<MemoryCard> {
  const now = deps.now ?? (() => new Date());
  const id = (deps.idGen ?? makeId)();
  const ts = now().toISOString();
  const draft: MemoryCard = {
    id,
    status: 'pending',
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
    transcript: input.transcript,
    desc: null,
    images: null,
    audioPath: null,
    visionAnalyzed: null,
    tags: null,
    confidence: null,
    source: 'text',
    retryCount: 0,
    nextRetryAt: null,
    lastError: null,
    createdAt: ts,
    updatedAt: ts,
  };
  insertCard(deps.db, draft);

  const categories = listCategories(deps.db);
  const system = buildP1System({
    categories: formatCategoriesForPrompt(categories),
    locations: formatLocationsForPrompt(listLocations(deps.db)),
  });
  const user = buildP1User(input.transcript);
  const call = (extra: string) =>
    deps.llm.chat(
      { system: system + extra, parts: [{ type: 'text', text: user }], temperature: 0.1 },
      deps.cfg,
    );

  try {
    const first = await call('');
    let parsed = parseModelJson(first.text, P1OutputSchema);
    if (!parsed.ok) {
      const second = await call('\n\n注意：只输出一个合法 JSON 对象，不要任何多余文字。');
      parsed = parseModelJson(second.text, P1OutputSchema);
    }
    if (!parsed.ok) {
      // 需求 3.4：重试 1 次仍失败 → 只保留原文，标记「待整理」
      markNeedsOrganize(deps.db, id, now());
      return getCard(deps.db, id)!;
    }
    const out = parsed.value;
    const category = out.category
      ? (categories.find((c) => c.name === out.category) ?? null)
      : null;
    const path = out.structure_type === 'item' && out.path ? resolvePath(deps.db, out.path) : null;
    const needsConfirm =
      (out.confidence != null && out.confidence < (deps.confirmThreshold ?? 0.6)) ||
      !category ||
      (out.structure_type === 'item' && !path);
    applyParseResult(
      deps.db,
      id,
      {
        structureType: out.structure_type,
        categoryId: category?.id ?? null,
        entity: out.entity,
        pathIds: path?.ids ?? null,
        pathNames: path?.namesStr ?? null,
        steps: out.steps.length > 0 ? out.steps.map((text) => ({ text, done: false })) : null,
        desc: out.desc,
        tags: out.tags,
        confidence: out.confidence ?? null,
        aliases: out.aliases,
      },
      needsConfirm,
      now(),
    );
    return getCard(deps.db, id)!;
  } catch (e) {
    markRetry(deps.db, id, e instanceof Error ? e.message : String(e), now());
    return getCard(deps.db, id)!;
  }
}
