import { expect, test } from 'vitest';
import { insertCard } from '../src/db/repository';
import { P2OutputSchema } from '../src/parse';
import { FakeLLMAdapter } from '../src/providers/fake';
import type { ProviderConfig } from '../src/providers/types';
import { adviseFromInventory } from '../src/search/advise';
import { buildInventory } from '../src/search/inventory';
import { searchCards } from '../src/search/service';
import { makeCard, makeDb } from './helpers';

const CFG: ProviderConfig = { providerType: 'fake', model: 'fake' };

/**
 * 推理题（advise）通道 —— 用户 2026-09-20 报告的「无脑搜索」。
 *
 * 场景：库里有 护照 / 螺丝刀 / 插线板 / 剃须刀，问「我去国外玩应该会用到哪些东西」。
 * 期望返回 护照、剃须刀（插线板视插座标准而定，应进 maybe 而不是被删掉或全留）。
 *
 * 这个场景在旧实现里**必然 0 条**：P2_SYSTEM 原来明令「绝不假设库里存在什么物品」，
 * 所以「护照」这两个字永远不会进入关键词；而「旅游」与「护照」零字面重叠，
 * 本地 FTS/LIKE 也永远匹配不上。缺的输入是**库存本身**，不是更好的关键词。
 */

const PASSPORT = makeCard({
  id: 'passport',
  entity: '护照',
  desc: '因私护照放在主卧床头柜第二层抽屉，和户口本放在一起。',
  pathNames: '主卧/床头柜',
  categoryId: 'cat_item',
});
const SCREWDRIVER = makeCard({
  id: 'screwdriver',
  entity: '螺丝刀',
  desc: '十字螺丝刀放在阳台工具柜最上层。',
  pathNames: '阳台/工具柜',
  categoryId: 'cat_item',
});
const POWERSTRIP = makeCard({
  id: 'powerstrip',
  entity: '插线板',
  desc: '五孔插线板收在书房桌下的收纳箱里。',
  pathNames: '书房/桌前',
  categoryId: 'cat_item',
});
const SHAVER = makeCard({
  id: 'shaver',
  entity: '剃须刀',
  desc: '电动剃须刀放在卫生间镜柜里，充电线在旁边。',
  pathNames: '卫生间/镜柜',
  categoryId: 'cat_item',
});

function seed(db: ReturnType<typeof makeDb>) {
  for (const c of [PASSPORT, SCREWDRIVER, POWERSTRIP, SHAVER]) insertCard(db, c);
}

const p2Advise = JSON.stringify({
  mode: 'advise',
  intent: 'unknown',
  keywords: [],
  synonyms: [],
  category: null,
  path_prefix: null,
  time_hint: null,
  match_mode: 'any',
  scenario: '出国旅游需要随身携带的物品',
  aspects: ['证件', '洗漱用品', '电子产品'],
  normalized_query: '出国旅游需要带哪些东西',
});

const p4Answer = JSON.stringify({
  picks: [
    { id: 'passport', why: '出境必备' },
    { id: 'shaver', why: '外出留宿要用' },
  ],
  maybe: [{ id: 'powerstrip', why: '取决于目的地插座标准' }],
  missing: ['转换插头'],
  answer: '出国你该带护照和剃须刀；插线板看目的地插座标准。库里还没有转换插头。',
});

test('P2 缺少 mode 字段时缺省为 locate —— 老模型的行为不会因此变差', () => {
  const parsed = P2OutputSchema.parse({ intent: 'find_item', keywords: ['护照'] });
  expect(parsed.mode).toBe('locate');
  expect(parsed.aspects).toEqual([]);
});

test('库存摘要：一条一行，含 id / 实体 / 分类 / 位置 / 简述', () => {
  const db = makeDb();
  seed(db);
  const inv = buildInventory(db);

  expect(inv.total).toBe(4);
  expect(inv.listed).toBe(4);
  expect(inv.truncated).toBe(false);
  expect(inv.text).toContain('序号 | id | 实体 | 分类 | 位置 | 简述');
  expect(inv.text).toContain('| passport | 护照 |');
  expect(inv.text).toContain('主卧/床头柜');
  expect(inv.text).toContain('| shaver | 剃须刀 |');
});

test('库存摘要：archived 不进清单（与记忆流一致）', () => {
  const db = makeDb();
  insertCard(db, makeCard({ id: 'gone', entity: '旧物', status: 'archived' }));
  insertCard(db, PASSPORT);
  const inv = buildInventory(db);
  expect(inv.total).toBe(1);
  expect(inv.text).not.toContain('旧物');
});

test('库存摘要：超出上界时写明截断，而不是静默变少', () => {
  const db = makeDb();
  for (let i = 0; i < 5; i++) insertCard(db, makeCard({ id: `c${i}`, entity: `物件${i}` }));
  const inv = buildInventory(db, { limit: 2 });
  expect(inv.total).toBe(5);
  expect(inv.listed).toBe(2);
  expect(inv.truncated).toBe(true);
  expect(inv.text).toContain('全库共 5 条');
  expect(inv.text).toContain('可能不全');
});

test('裁决：模型编造的 id 被丢弃，同一张卡不会同时出现在两档', async () => {
  const db = makeDb();
  seed(db);
  const inv = buildInventory(db);
  const fake = new FakeLLMAdapter([
    JSON.stringify({
      picks: [{ id: 'passport', why: '出境必备' }, { id: '不存在', why: '编的' }],
      maybe: [{ id: 'passport', why: '重复' }, { id: 'shaver', why: '看情况' }],
      missing: [],
      answer: 'ok',
    }),
  ]);

  const res = await adviseFromInventory({ llm: fake, cfg: CFG }, '出国带什么', '出国旅游', inv);
  expect(res.ok).toBe(true);
  expect(res.picks.map((p) => p.id)).toEqual(['passport']);
  expect(res.maybe.map((m) => m.id)).toEqual(['shaver']);
});

test('裁决：模型只回 id 字符串（不带 why）也能解析', async () => {
  const db = makeDb();
  seed(db);
  const inv = buildInventory(db);
  const fake = new FakeLLMAdapter([
    JSON.stringify({ picks: ['passport'], maybe: ['shaver'], missing: [], answer: 'ok' }),
  ]);
  const res = await adviseFromInventory({ llm: fake, cfg: CFG }, '出国带什么', '出国旅游', inv);
  expect(res.picks.map((p) => p.id)).toEqual(['passport']);
  expect(res.picks[0].why).toBe('');
});

test('裁决：调用失败时 ok=false，由上层退到字面兜底', async () => {
  const db = makeDb();
  seed(db);
  const inv = buildInventory(db);
  const res = await adviseFromInventory({ llm: new FakeLLMAdapter([]), cfg: CFG }, 'q', 's', inv);
  expect(res.ok).toBe(false);
  expect(res.error).toBeTruthy();
});

test('端到端：出国玩该带什么 → 护照与剃须刀被挑出来，插线板进「看情况」', async () => {
  const db = makeDb();
  seed(db);
  const fake = new FakeLLMAdapter([p2Advise, p4Answer]);

  const res = await searchCards(
    { db, llm: fake, cfg: CFG },
    '我去国外玩应该会用到哪些东西',
  );

  expect(res.advice?.ok).toBe(true);
  expect(res.cards.map((c) => c.id)).toEqual(['passport', 'shaver', 'powerstrip']);
  expect(res.advice?.picks.map((p) => p.id)).toEqual(['passport', 'shaver']);
  expect(res.advice?.maybe.map((m) => m.id)).toEqual(['powerstrip']);
  expect(res.advice?.missing).toEqual(['转换插头']);
  expect(res.usedFallback).toBe(false);
  // 走的是裁决通道，不是字面命中 —— 所以这些卡不该是 SQL 查出来的
  expect(res.relaxed).toBeUndefined();
});

test('端到端：裁决时模型真的看到了库存（缺的输入是库存，不是关键词）', async () => {
  const db = makeDb();
  seed(db);
  const fake = new FakeLLMAdapter([p2Advise, p4Answer]);
  await searchCards({ db, llm: fake, cfg: CFG }, '我去国外玩应该会用到哪些东西');

  expect(fake.requests).toHaveLength(2);
  const p4 = fake.requests[1].parts.map((p) => (p.type === 'text' ? p.text : '')).join('');
  // 四张卡都在清单里 —— 螺丝刀也发了（模型必须有机会说它「不相关」）
  for (const name of ['护照', '螺丝刀', '插线板', '剃须刀']) expect(p4).toContain(name);
  expect(p4).toContain('出国旅游需要随身携带的物品');
  // 模型必须被要求用常识判断，否则它只会做字面比较
  const system = fake.requests[1].system ?? '';
  expect(system).toContain('用常识判断');
});

test('端到端：advise 模式下 keywords 为空也照走裁决（不能退化成「听不懂」）', async () => {
  const db = makeDb();
  seed(db);
  const fake = new FakeLLMAdapter([p2Advise, p4Answer]);

  const res = await searchCards({ db, llm: fake, cfg: CFG }, '我去国外玩应该会用到哪些东西');
  expect(fake.requests).toHaveLength(2);
  expect(res.unclear).toBe(false);
  expect(res.advice).toBeDefined();
});

test('端到端：空库不发第二次调用，直接说明还没有记忆', async () => {
  const db = makeDb();
  const fake = new FakeLLMAdapter([p2Advise]);

  const res = await searchCards({ db, llm: fake, cfg: CFG }, '我去国外玩应该会用到哪些东西');
  expect(fake.requests).toHaveLength(1);
  expect(res.cards).toEqual([]);
  expect(res.advice?.answer).toContain('还是空的');
});

test('端到端：裁决失败退到字面兜底，并标记 usedFallback', async () => {
  const db = makeDb();
  seed(db);
  // 只给 P2，P4 那一发直接抛错（模拟模型不可达）
  const fake = new FakeLLMAdapter([p2Advise]);

  const res = await searchCards({ db, llm: fake, cfg: CFG }, '我去国外玩应该会用到哪些东西');
  expect(res.usedFallback).toBe(true);
  expect(res.advice).toBeUndefined();
});

test('端到端：locate 模式不受影响，仍走字面检索', async () => {
  const db = makeDb();
  insertCard(db, PASSPORT);
  const fake = new FakeLLMAdapter([
    JSON.stringify({
      mode: 'locate',
      intent: 'find_item',
      keywords: ['护照'],
      synonyms: [],
      category: null,
      path_prefix: null,
      time_hint: null,
      match_mode: 'any',
      scenario: null,
      aspects: [],
      normalized_query: '护照放在哪里',
    }),
  ]);

  const res = await searchCards({ db, llm: fake, cfg: CFG }, '我护照放哪了');
  expect(res.cards.map((c) => c.id)).toEqual(['passport']);
  expect(res.advice).toBeUndefined();
  expect(fake.requests).toHaveLength(1);
});

test('端到端：裁决一条都没挑中、但字面命中时，不让它变成静默空结果', async () => {
  const db = makeDb();
  insertCard(db, PASSPORT);
  // 模拟「定位题被误判成推理题」：模型说库里没相关的，但字面其实查得到
  const fake = new FakeLLMAdapter([
    p2Advise,
    JSON.stringify({ picks: [], maybe: [], missing: [], answer: '库里没找到相关的。' }),
  ]);

  const res = await searchCards({ db, llm: fake, cfg: CFG }, '护照在哪');
  expect(res.cards.map((c) => c.id)).toEqual(['passport']);
  // 这里的 usedFallback 是「模型没挑出来，下面是字面命中的」，
  // 不是「模型不可达」—— UI 必须按前者措辞（见 index.tsx 的 advice 分支）
  expect(res.usedFallback).toBe(true);
  expect(res.advice).toBeDefined();
});
