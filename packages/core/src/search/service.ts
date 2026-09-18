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
  llm: LLMProviderAdapter;
  cfg: ProviderConfig;
}

export interface SearchResult {
  cards: MemoryCard[];
  /** P2 失败/无网时走原始 query 直查（需求 5.3 L1 兜底） */
  usedFallback: boolean;
  /** intent 识别不出来，UI 应提示换种说法，而非展示空结果 */
  unclear: boolean;
  p2: P2Output | null;
}

export async function searchCards(deps: SearchDeps, query: string): Promise<SearchResult> {
  let p2: P2Output | null = null;
  try {
    const system = buildP2System({
      categories: formatCategoriesForPrompt(listCategories(deps.db)),
      locations: formatLocationsForPrompt(listLocations(deps.db)),
    });
    const res = await deps.llm.chat(
      { system, parts: [{ type: 'text', text: query }], temperature: 0.1 },
      deps.cfg,
    );
    const parsed = parseModelJson(res.text, P2OutputSchema);
    if (parsed.ok) p2 = parsed.value;
  } catch {
    p2 = null;
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
