import { parseModelJson, P3OutputSchema } from '../parse';
import { buildP3Input, buildP3System } from '../prompts/render';
import type { LLMProviderAdapter, ProviderConfig } from '../providers/types';
import type { MemoryCard } from '../types';

/** L2 只送命中片段，**永不发送全库**（需求 5.3 的硬约束） */
export const L2_MAX_SNIPPETS = 8;

/** 单条片段里描述与原文各自的截断长度，给请求体一个上界 */
const DESC_CHARS = 240;
const TRANSCRIPT_CHARS = 160;

export interface AnswerDeps {
  llm: LLMProviderAdapter;
  cfg: ProviderConfig;
}

export interface AnswerResult {
  ok: boolean;
  answer: string;
  /** 只保留真的在候选里的 id —— 模型编出来的 id 一律丢掉，否则高亮会指向不存在的卡 */
  hitIds: string[];
  suggest: string;
  error?: string;
}

function clip(value: string | null | undefined, max: number): string {
  if (!value) return '';
  const text = value.trim();
  return text.length > max ? `${text.slice(0, max)}…` : text;
}

/** 把命中卡片压成 P3 能吃的片段块。id 必须带上，`hit_ids` 要靠它对回来做高亮 */
export function formatSnippets(cards: MemoryCard[], limit = L2_MAX_SNIPPETS): string {
  if (cards.length === 0) return '（没有命中任何片段）';
  return cards
    .slice(0, limit)
    .map((card, index) => {
      const lines = [`[${index + 1}] id=${card.id}`];
      if (card.pathNames) lines.push(`位置：${card.pathNames}`);
      if (card.entity) lines.push(`实体：${card.entity}`);
      if (card.desc) lines.push(`描述：${clip(card.desc, DESC_CHARS)}`);
      const transcript = clip(card.transcript, TRANSCRIPT_CHARS);
      if (transcript && transcript !== card.desc) lines.push(`原文：${transcript}`);
      lines.push(`记录时间：${card.createdAt.slice(0, 10)}`);
      return lines.join('\n');
    })
    .join('\n\n');
}

/**
 * L2 答案组织：把 L1 命中的 top-N 条目交给主模型组织成答案卡片。
 *
 * 触发时机按需求 5.3：**本地无结果或用户手动触发**，不是每次搜索都跑——
 * 每次跑会白白多花一次模型调用，而 L1 命中的卡片列表本身往往就够用。
 * 片段为空时仍然值得调用：P3 的约束是「片段不足以回答时直接说没找到并说明缺什么线索」。
 */
export async function answerFromCards(
  deps: AnswerDeps,
  query: string,
  cards: MemoryCard[],
): Promise<AnswerResult> {
  try {
    const res = await deps.llm.chat(
      {
        system: buildP3System(),
        parts: [{ type: 'text', text: buildP3Input(query, formatSnippets(cards)) }],
        temperature: 0.1,
      },
      deps.cfg,
    );
    const parsed = parseModelJson(res.text, P3OutputSchema);
    if (!parsed.ok) {
      return { ok: false, answer: '', hitIds: [], suggest: '', error: parsed.error };
    }
    const known = new Set(cards.map((c) => c.id));
    return {
      ok: true,
      answer: parsed.value.answer,
      hitIds: parsed.value.hit_ids.filter((id) => known.has(id)),
      suggest: parsed.value.suggest,
    };
  } catch (e) {
    return {
      ok: false,
      answer: '',
      hitIds: [],
      suggest: '',
      error: e instanceof Error ? e.message : String(e),
    };
  }
}
