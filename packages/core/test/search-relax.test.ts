import { expect, test } from 'vitest';
import { insertCard } from '../src/db/repository';
import type { P2Output } from '../src/parse';
import type { LLMProviderAdapter } from '../src/providers/types';
import { buildSearch, relaxations } from '../src/search/builder';
import { searchCards } from '../src/search/service';
import { makeCard, makeDb } from './helpers';

/**
 * 「P2 的决策」如何决定一条查询能不能命中 —— 用一次真实的用户报告固化下来。
 *
 * 用户观察：搜「我的护照在哪」能命中（标签 出行 / 证件）；搜「国外出行需要准备哪些证件」
 * 结果为空，但按语义明明是同一张卡。这里证明**卡与索引都没问题**
 * —— 只要「证件」进了关键词且没被多余约束挡住，就一定能搜到。
 *
 * 由此暴露的三类失败，本轮（第十四版）修了两类：
 *   ① `match_mode=all` / ② 分类被意图误推  ⇒ **逐级放宽**修复（`relaxations`）
 *   ③ `intent=unknown`（一次查询都不发）    ⇒ **退回字面兜底**修复
 * 剩下 ③'「关键词里干脆没有那个词」是 P2_SYSTEM 规则 2（不许猜库里的实体）的必然代价，
 * 放宽救不回来，属于设计取舍而非 bug。
 */

const PASSPORT = makeCard({
  id: 'passport',
  entity: '护照',
  desc: '护照放在书房第二个抽屉里，和身份证、户口本放在一起。',
  tags: ['出行', '证件'],
  categoryId: 'cat_item',
});

function p2(over: Partial<P2Output>): P2Output {
  return {
    intent: 'find_item',
    keywords: [],
    synonyms: [],
    category: null,
    path_prefix: null,
    time_hint: null,
    match_mode: 'any',
    normalized_query: null,
    ...over,
  };
}

/** 假 LLM：直接回吐给定的 P2 JSON，模拟「模型这么判了」 */
function fakeLlm(out: P2Output): LLMProviderAdapter {
  return { chat: async () => ({ text: JSON.stringify(out) }) } as unknown as LLMProviderAdapter;
}

async function run(out: P2Output, query = '国外出行需要准备哪些证件') {
  const db = makeDb();
  insertCard(db, PASSPORT);
  return searchCards({ db, llm: fakeLlm(out), cfg: {} as never }, query);
}

test('前提：「证件」在关键词里且 any ⇒ 严格条件自己就命中，不走放宽', async () => {
  const res = await run(p2({ keywords: ['国外', '出行', '证件', '准备'], match_mode: 'any' }));
  expect(res.cards.map((c) => c.id)).toEqual(['passport']);
  expect(res.relaxed).toBeFalsy();
  expect(res.unclear).toBe(false);
});

test('前提：两字词走 LIKE 降级，且 LIKE 覆盖 tags 列', async () => {
  const res = await run(p2({ keywords: ['证件'], category: '物品存取' }));
  expect(res.cards.map((c) => c.id)).toEqual(['passport']);
});

test('修复 ①：match_mode=all 太严 ⇒ 放宽为 any 后命中，并标记 relaxed', async () => {
  const res = await run(p2({ keywords: ['国外', '出行', '证件', '准备'], match_mode: 'all' }));
  expect(res.cards.map((c) => c.id)).toEqual(['passport']);
  expect(res.relaxed).toBe(true);
  expect(res.usedFallback).toBe(false);
});

test('修复 ②：意图被判成待买补货 ⇒ 去掉分类过滤后命中，并标记 relaxed', async () => {
  const res = await run(p2({ intent: 'list_todo', keywords: ['证件', '准备'], category: '待买补货' }));
  expect(res.cards.map((c) => c.id)).toEqual(['passport']);
  expect(res.relaxed).toBe(true);
});

test('修复 ③：intent=unknown 不再直接返回空，改走字面兜底（短查询能命中）', async () => {
  // 旧行为：buildSearch 返 null ⇒ 一次查询都不发 ⇒ 必然 0 条。
  // 新行为：按用户原话字面搜一遍。
  const res = await run(p2({ intent: 'unknown', keywords: [] }), '护照');
  expect(res.cards.map((c) => c.id)).toEqual(['passport']);
  expect(res.usedFallback).toBe(true);
  expect(res.unclear).toBe(true); // 仍要告诉用户「模型没听懂」，只是这次有兜底
});

test('设计取舍：关键词里根本没有「证件」⇒ 放宽也救不回来（约束不是问题）', async () => {
  const res = await run(p2({ keywords: ['国外', '准备'], match_mode: 'any' }));
  expect(res.cards).toEqual([]);
  expect(res.relaxed).toBeFalsy();
  expect(res.usedFallback).toBe(false);
});

test('relaxations：按「去分类 → 去时间位置 → all转any」累积放宽，且不动 ftsExpr', () => {
  const s = buildSearch({
    p2: p2({
      keywords: ['国外', '出行', '证件'],
      category: '物品存取',
      path_prefix: ['主卧'],
      time_hint: 'this_year',
      match_mode: 'all',
    }),
    resolveCategoryId: () => 'cat_item',
  });
  expect(s).not.toBeNull();
  const ladder = relaxations(s!);
  expect(ladder).toHaveLength(3);
  expect(ladder[0].categoryId).toBeNull();
  expect(ladder[0].pathPrefixLike).not.toBeNull();
  expect(ladder[1].pathPrefixLike).toBeNull();
  expect(ladder[1].sinceIso).toBeNull();
  expect(ladder[2].matchMode).toBe('any');
  // 语义核心不能被改：放宽只动「过滤与连接方式」
  for (const step of ladder) {
    expect(step.ftsExpr).toBe(s!.ftsExpr);
    expect(step.likeTerms).toEqual(s!.likeTerms);
  }
});
