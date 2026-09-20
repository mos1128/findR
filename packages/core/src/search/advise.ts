import { parseModelJson, P4OutputSchema } from '../parse';
import { buildP4Input, buildP4System } from '../prompts/render';
import type { LLMProviderAdapter, ProviderConfig } from '../providers/types';
import type { MemoryCard } from '../types';
import type { Inventory } from './inventory';

export interface AdviceItem {
  id: string;
  card: MemoryCard;
  /** 模型给的一句话理由（必需：为什么必需；看情况：取决于什么） */
  why: string;
}

export interface AdviceResult {
  ok: boolean;
  /** 必需 */
  picks: AdviceItem[];
  /** 看情况 */
  maybe: AdviceItem[];
  /** 库里没有、但这个情景确实需要的东西 */
  missing: string[];
  answer: string;
  error?: string;
}

export interface AdviceDeps {
  llm: LLMProviderAdapter;
  cfg: ProviderConfig;
}

/**
 * 推理题的裁决：把「情景 + 整个记忆库的清单」交给主模型逐条判相关性。
 *
 * 与 L2（answer.ts）的区别是根本性的，不能合并：
 * - L2 的约束是「**不得补充片段之外的任何信息**」—— 它只能复述已找到的东西；
 * - 这里的约束恰恰相反，**必须用常识判断「那个场合用不用得上」**——
 *   因为答案根本不在库里（「出国 → 护照」是世界知识，不是字面相似度）。
 * 把两件事塞进同一个 prompt，只会让两条路都变弱。
 *
 * 三道防线保证它不会乱说：只能挑清单里存在的 id（编的一律丢）、
 * 拿不准的进 maybe 而不是被静默删掉、库里的缺口写进 missing 而不是假装没有。
 */
export async function adviseFromInventory(
  deps: AdviceDeps,
  query: string,
  scenario: string,
  inventory: Inventory,
): Promise<AdviceResult> {
  try {
    const res = await deps.llm.chat(
      {
        system: buildP4System(),
        parts: [
          {
            type: 'text',
            text: buildP4Input(query, scenario, inventory.total, inventory.text),
          },
        ],
        temperature: 0.1,
      },
      deps.cfg,
    );
    const parsed = parseModelJson(res.text, P4OutputSchema);
    if (!parsed.ok) {
      return { ok: false, picks: [], maybe: [], missing: [], answer: '', error: parsed.error };
    }

    const byId = new Map(inventory.cards.map((c) => [c.id, c]));
    const take = (refs: { id: string; why: string }[]): AdviceItem[] => {
      const seen = new Set<string>();
      const out: AdviceItem[] = [];
      for (const ref of refs) {
        const card = byId.get(ref.id);
        // 模型编出来的 id、或重复出现的同一张卡，一律丢掉 —— 否则列表会指向不存在的卡
        if (!card || seen.has(card.id)) continue;
        seen.add(card.id);
        out.push({ id: card.id, card, why: ref.why });
      }
      return out;
    };

    const picks = take(parsed.value.picks);
    const pickedIds = new Set(picks.map((p) => p.id));
    // 同一张卡同时进了两档时以 picks 为准，否则列表里会出现两张一样的卡
    const maybe = take(parsed.value.maybe).filter((m) => !pickedIds.has(m.id));

    return {
      ok: true,
      picks,
      maybe,
      missing: parsed.value.missing.map((m) => m.trim()).filter((m) => m.length > 0),
      answer: parsed.value.answer,
    };
  } catch (e) {
    return {
      ok: false,
      picks: [],
      maybe: [],
      missing: [],
      answer: '',
      error: e instanceof Error ? e.message : String(e),
    };
  }
}
