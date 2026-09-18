import type { SqliteDriver } from '../db/driver';
import {
  executeSearch,
  expandTermsByAliases,
  listCategories,
  listLocations,
  resolveCategoryId,
} from '../db/repository';
import { parseModelJson, type P2Output, P2OutputSchema } from '../parse';
import {
  buildP2System,
  formatCategoriesForPrompt,
  formatLocationsForPrompt,
} from '../prompts/render';
import type { LLMProviderAdapter, ProviderConfig } from '../providers/types';
import type { MemoryCard } from '../types';
import { buildRawSearch, buildSearch } from './builder';

export interface SearchDeps {
  db: SqliteDriver;
  /**
   * 未配置主模型时为 null / undefined。
   *
   * 此时**跳过 P2、直接走字面兜底** —— 与「配了模型但端点不可达」是同一条路。
   * 字面检索（FTS + LIKE）本来就不依赖模型，不该因为没配模型而整条检索不可用：
   * 隐私优先、长期离线、只想当本地记事本的用户，是一等公民而不是残废状态。
   */
  llm?: LLMProviderAdapter | null;
  cfg?: ProviderConfig | null;
}

export interface SearchResult {
  cards: MemoryCard[];
  /** P2 失败/无网/未配模型时走原始 query 直查（需求 5.3 L1 兜底） */
  usedFallback: boolean;
  /** intent 识别不出来，UI 应提示换种说法，而非展示空结果 */
  unclear: boolean;
  p2: P2Output | null;
}

export async function searchCards(deps: SearchDeps, query: string): Promise<SearchResult> {
  let p2: P2Output | null = null;
  // 没有模型 ⇒ 跳过 P2、直接走字面兜底。这里**绝不能抛错**：抛了连字面检索都没了。
  // 「配了模型但端点不通」走的是兜底，「压根不想配模型」却全废 —— 同一件事两条路，
  // 而且更常见的那条（隐私优先 / 长期离线）反而更不可用，这是实现走偏，不是设计意图。
  if (deps.llm && deps.cfg) {
    const { llm, cfg } = deps;
    try {
      const system = buildP2System({
        categories: formatCategoriesForPrompt(listCategories(deps.db)),
        locations: formatLocationsForPrompt(listLocations(deps.db)),
      });
      const res = await llm.chat(
        { system, parts: [{ type: 'text', text: query }], temperature: 0.1 },
        cfg,
      );
      const parsed = parseModelJson(res.text, P2OutputSchema);
      if (parsed.ok) p2 = parsed.value;
    } catch {
      p2 = null;
    }
  }

  if (p2) {
    if (p2.intent === 'unknown' || p2.keywords.length === 0) {
      return { cards: [], usedFallback: false, unclear: true, p2 };
    }
    const expanded = expandTermsByAliases(deps.db, [...p2.keywords, ...p2.synonyms]);
    const built = buildSearch({
      p2: { ...p2, synonyms: [...new Set([...p2.synonyms, ...expanded])] },
      resolveCategoryId: (name) => resolveCategoryId(deps.db, name),
    });
    if (!built) return { cards: [], usedFallback: false, unclear: true, p2 };
    return { cards: executeSearch(deps.db, built), usedFallback: false, unclear: false, p2 };
  }

  return {
    cards: executeSearch(deps.db, buildRawSearch(query)),
    usedFallback: true,
    unclear: false,
    p2: null,
  };
}
