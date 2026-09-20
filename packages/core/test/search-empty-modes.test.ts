import { expect, test } from 'vitest';
import { insertCard } from '../src/db/repository';
import type { P2Output } from '../src/parse';
import type { LLMProviderAdapter } from '../src/providers/types';
import { searchCards } from '../src/search/service';
import { makeCard, makeDb } from './helpers';

/**
 * 「模型给出的 P2 决策」如何决定一条查询能不能命中 —— 用一次真实的用户报告固化下来。
 *
 * 用户观察：搜「我的护照在哪」能命中（标签 出行 / 证件）；搜「国外出行需要准备哪些证件」
 * 结果为空，但按语义明明是同一张卡。这里证明**卡与索引都没问题**
 * —— 只要 P2 把「证件」放进关键词、且不误加约束，就一定能搜到；
 * 空结果一定来自 P2 的某个决策。
 *
 * 三种「静默空」是产品级的坑：用户只看到「检索结果 0 条」，不知道是说法问题、
 * 还是卡片丢了。只有 intent=unknown 会在 UI 上给提示（unclear）。
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

async function run(out: P2Output) {
  const db = makeDb();
  insertCard(db, PASSPORT);
  return searchCards({ db, llm: fakeLlm(out), cfg: {} as never }, '国外出行需要准备哪些证件');
}

test('关键前提：「证件」在关键词里且 any 模式 ⇒ 一定能命中（证明卡与索引没问题）', async () => {
  const res = await run(p2({ keywords: ['国外', '出行', '证件', '准备'], match_mode: 'any' }));
  expect(res.cards.map((c) => c.id)).toEqual(['passport']);
  expect(res.unclear).toBe(false);
});

test('关键前提：两字词走 LIKE 降级，tags 列也在 LIKE 范围内', async () => {
  // 「证件」只有两字，trigram 产不出 token，靠 splitTerms 降级成 LIKE；
  // 且 LIKE 必须带上 c.tags，否则只存标签的卡搜不到
  const res = await run(p2({ keywords: ['证件'], category: '物品存取' }));
  expect(res.cards.map((c) => c.id)).toEqual(['passport']);
});

test('静默空 ①：match_mode=all 且含卡里没有的词 ⇒ 0 条（AND 过严）', async () => {
  const res = await run(p2({ keywords: ['国外', '出行', '证件', '准备'], match_mode: 'all' }));
  expect(res.cards).toEqual([]);
  // 没有 unclear 标志 ⇒ UI 不会有任何提示，用户只看到「0 条」
  expect(res.unclear).toBe(false);
});

test('静默空 ②：意图被判成待买补货 ⇒ 分类过滤把物品卡整批剔掉', async () => {
  const res = await run(p2({ intent: 'list_todo', keywords: ['证件', '准备'], category: '待买补货' }));
  expect(res.cards).toEqual([]);
  expect(res.unclear).toBe(false);
});

test('静默空 ③：关键词里没有「证件」（模型没敢扩同义词）⇒ 0 条', async () => {
  const res = await run(p2({ keywords: ['国外', '准备'], match_mode: 'any' }));
  expect(res.cards).toEqual([]);
  expect(res.unclear).toBe(false);
});

test('唯一有提示的失败：intent=unknown ⇒ 0 条且 unclear=true', async () => {
  const res = await run(p2({ intent: 'unknown', keywords: [] }));
  expect(res.cards).toEqual([]);
  expect(res.unclear).toBe(true);
});
