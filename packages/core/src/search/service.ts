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
import { adviseFromInventory, type AdviceResult } from './advise';
import { buildRawSearch, buildSearch, relaxations } from './builder';
import { buildInventory } from './inventory';

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
  /** intent 识别不出来（或没给出可用关键词），UI 应提示换种说法 */
  unclear: boolean;
  p2: P2Output | null;
  /**
   * 严格条件 0 命中、靠**放宽约束**（去分类 / 去时间位置 / all→any）才拿到的结果。
   * UI 必须说明：这批结果比用户原话宽，不说明就会被误当成「严格匹配」。
   */
  relaxed?: boolean;
  /**
   * 推理题（advise）的裁决结果。有值时 `cards` 是**裁决后**的清单
   * （必需在前、看情况在后），不再是字面命中 —— UI 必须据此换一套呈现。
   */
  advice?: AdviceResult;
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

  // 推理题：答案不在库里，字面检索对这类问题**必然 0 条**，改走「整库清单 → 模型裁决」。
  // 必须放在下面的关键词检查**之前** —— advise 模式下 keywords 恒为空，
  // 否则会被当成「模型没听懂」而退化，正是要修的那个毛病。
  if (p2 && p2.mode === 'advise') return adviseSearch(deps, query, p2);

  if (p2 && p2.intent !== 'unknown' && p2.keywords.length > 0) {
    const expanded = expandTermsByAliases(deps.db, [...p2.keywords, ...p2.synonyms]);
    const built = buildSearch({
      p2: { ...p2, synonyms: [...new Set([...p2.synonyms, ...expanded])] },
      resolveCategoryId: (name) => resolveCategoryId(deps.db, name),
    });
    if (built) {
      const strict = executeSearch(deps.db, built);
      if (strict.length > 0) return { cards: strict, usedFallback: false, unclear: false, p2 };

      // 严格条件一条都没命中 ⇒ 逐级放宽再试。
      // 放宽**只跑本地 SQL，不额外调用模型**，所以在真机上几乎没有额外延迟。
      // 顺序与理由见 builder.ts 的 `relaxations`。
      for (const relaxed of relaxations(built)) {
        const got = executeSearch(deps.db, relaxed);
        if (got.length > 0) {
          return { cards: got, usedFallback: false, unclear: false, p2, relaxed: true };
        }
      }
      // 放宽也救不回来 —— 说明约束不是问题，是真的没有（见 test/search-relax.test.ts 的用例 ③）
      return { cards: [], usedFallback: false, unclear: false, p2 };
    }
  }

  // 走到这里 = 没配模型 / P2 调用失败 / P2 说听不懂 / 关键词为空 ⇒ 一律退回**字面兜底**。
  //
  // 原来「P2 说听不懂」是直接 return 空 + unclear —— 于是「配了模型但模型没听懂」
  // 比「压根没配模型」还不可用：同一件事两条路，而后者明明有兜底。
  // 现在统一：听不懂也要按用户原话再字面搜一遍，搜不到再说搜不到。
  return {
    cards: executeSearch(deps.db, buildRawSearch(query)),
    usedFallback: true,
    unclear: p2 !== null,
    p2,
  };
}

/**
 * 推理题（advise）的执行：整库清单 → 模型逐条裁决。
 *
 * 与定位题的差别不只在 prompt，还在**返回的 cards 从何而来**：
 * 定位题的 cards 是本地 SQL 命中的；这里的 cards 是模型挑出来的
 * （必需在前、看情况在后），**可能一条都没有**——那也是一种正确答案
 * （「你库里没有适合这次出行的东西，你还缺转换插头」）。
 */
async function adviseSearch(
  deps: SearchDeps,
  query: string,
  p2: P2Output,
): Promise<SearchResult> {
  const { llm, cfg } = deps;
  // 调用方已用 `deps.llm && deps.cfg` 保证非空，这里只是把类型收窄
  if (!llm || !cfg) {
    return { cards: [], usedFallback: true, unclear: false, p2 };
  }

  // 排序提示词：优先用 P2 给出的「这个情景通常需要什么类别」（`aspects` 是通用名词，
  // 命中率最高），再补情景描述与用户原句。**排序必须在截断之前**，
  // 否则库一大，「最近的 200 条」就会把去年记的护照挤出清单（见 inventory.ts）。
  const inventory = buildInventory(deps.db, {
    terms: [...p2.aspects, p2.scenario ?? '', query],
  });
  // 空库没必要花一次调用：没有任何库存，「你需要什么」无从谈起
  if (inventory.cards.length === 0) {
    return {
      cards: [],
      usedFallback: false,
      unclear: false,
      p2,
      advice: {
        ok: true,
        picks: [],
        maybe: [],
        missing: [],
        answer: '记忆库还是空的，先记一条再问我。',
      },
    };
  }

  const res = await adviseFromInventory({ llm, cfg }, query, p2.scenario?.trim() || query, inventory);
  if (!res.ok) {
    // 裁决失败 ⇒ 退到字面兜底，与「模型不可达」同一条路，并让 UI 说明走的是哪条
    return {
      cards: executeSearch(deps.db, buildRawSearch(query)),
      usedFallback: true,
      unclear: false,
      p2,
    };
  }

  const picked = [...res.picks, ...res.maybe];
  if (picked.length > 0) {
    return {
      cards: picked.map((item) => item.card),
      usedFallback: false,
      unclear: false,
      p2,
      advice: res,
    };
  }

  // 裁决一条都没挑中。这可能是真的（库里确实没有适合这次出行的东西），
  // 也可能是 P2 把一道定位题误判成了推理题。
  // 本地字面检索是**零成本、零延迟**的，顺手跑一次：它若命中了东西，就把这批结果
  // 一并给出（advice 仍然保留，答案与 missing 照常显示），
  // 别让一个模型判断变成一次静默的空结果 —— 与「模型不可达必退字面兜底」是同一条原则。
  const literal = executeSearch(deps.db, buildRawSearch(query));
  if (literal.length > 0) {
    return { cards: literal, usedFallback: true, unclear: false, p2, advice: res };
  }

  return { cards: [], usedFallback: false, unclear: false, p2, advice: res };
}
