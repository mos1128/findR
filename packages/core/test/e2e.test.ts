import { expect, test } from 'vitest';
import { getCard, upsertLocation } from '../src/db/repository';
import { ingestText } from '../src/pipeline/ingest';
import { FakeLLMAdapter } from '../src/providers/fake';
import type { ProviderConfig } from '../src/providers/types';
import { searchCards } from '../src/search/service';
import { makeDb } from './helpers';

const CFG: ProviderConfig = { providerType: 'fake', model: 'fake' };

const P1_DOWN_JACKET = JSON.stringify({
  structure_type: 'item',
  category: '物品存取',
  entity: '羽绒服',
  aliases: ['厚外套', '冬季外套'],
  path: ['主卧', '衣柜'],
  path_matched: true,
  path_suggestion: '衣柜最下层的纸箱',
  steps: [],
  desc: '羽绒服抽真空收在主卧衣柜顶层，也叫厚外套、冬季外套，黑色长款，和去年的长款羽绒服放在一起。',
  tags: ['换季', '冬季'],
  confidence: 0.86,
  missing: [],
  ask: '',
});

const P2_COAT = JSON.stringify({
  intent: 'find_item',
  keywords: ['厚外套'],
  synonyms: ['羽绒服'],
  category: '物品存取',
  path_prefix: null,
  time_hint: null,
  match_mode: 'any',
  normalized_query: '厚外套放在哪里',
});

const P1_PASSPORT = JSON.stringify({
  structure_type: 'item',
  category: '物品存取',
  entity: '护照',
  aliases: ['出入境证件'],
  path: null,
  path_matched: false,
  path_suggestion: null,
  steps: [],
  desc: '护照放在书房抽屉的文件袋里，出国证件。',
  tags: ['证件'],
  confidence: 0.9,
  missing: [],
  ask: '',
});

const P2_PASSPORT = JSON.stringify({
  intent: 'find_item',
  keywords: ['护照'],
  synonyms: [],
  category: '物品存取',
  path_prefix: null,
  time_hint: null,
  match_mode: 'any',
  normalized_query: '护照放在哪里',
});

test('M0 验收：文本录入 → P1 → 入库 → 检索 全链路', async () => {
  const db = makeDb();
  upsertLocation(db, { id: 'loc_master', parentId: null, name: '主卧', sort: 0 });
  upsertLocation(db, { id: 'loc_wardrobe', parentId: 'loc_master', name: '衣柜', sort: 0 });
  const llm = new FakeLLMAdapter([P1_DOWN_JACKET, P2_COAT]);

  const card = await ingestText(
    { db, llm, cfg: CFG },
    { transcript: '羽绒服真空袋收进主卧衣柜顶上了，跟去年那件长款的放一起' },
  );
  expect(card.status).toBe('active');
  expect(card.entity).toBe('羽绒服');
  expect(card.pathIds).toEqual(['loc_master', 'loc_wardrobe']);
  expect(card.pathNames).toBe('主卧/衣柜');
  expect(card.needsConfirm).toBe(false);
  expect(card.tags).toEqual(['换季', '冬季']);
  expect(card.desc).toContain('厚外套');

  const res = await searchCards({ db, llm, cfg: CFG }, '我那件厚外套放哪了？');
  expect(res.usedFallback).toBe(false);
  expect(res.unclear).toBe(false);
  expect(res.cards.length).toBeGreaterThan(0);
  expect(res.cards[0].entity).toBe('羽绒服');
  expect(llm.requests.length).toBe(2);
});

test('两字词走 LIKE 降级仍可命中；item 无位置时标记待确认', async () => {
  const db = makeDb();
  const llm = new FakeLLMAdapter([P1_PASSPORT, P2_PASSPORT]);
  const card = await ingestText({ db, llm, cfg: CFG }, { transcript: '护照放书房抽屉了' });
  expect(card.entity).toBe('护照');
  expect(card.needsConfirm).toBe(true);
  const res = await searchCards({ db, llm, cfg: CFG }, '护照在哪');
  expect(res.cards.map((c) => c.entity)).toContain('护照');
});

test('P2 调用失败 → 原始 query 兜底直查（无网可用）', async () => {
  const db = makeDb();
  const llm = new FakeLLMAdapter([P1_PASSPORT]);
  await ingestText({ db, llm, cfg: CFG }, { transcript: '护照放书房抽屉了' });
  const offline = new FakeLLMAdapter(); // 空队列 → chat 抛错
  const res = await searchCards({ db, llm: offline, cfg: CFG }, '护照');
  expect(res.usedFallback).toBe(true);
  expect(res.cards.map((c) => c.entity)).toContain('护照');
});

test('P1 两次解析失败 → 待整理，原文保留', async () => {
  const db = makeDb();
  const llm = new FakeLLMAdapter(['抱歉，我无法整理这个', '仍然不是 JSON 格式']);
  const card = await ingestText({ db, llm, cfg: CFG }, { transcript: '护照放书房抽屉了' });
  expect(card.status).toBe('active');
  expect(card.needsOrganize).toBe(true);
  expect(card.transcript).toBe('护照放书房抽屉了');
  expect(card.desc).toBeNull();
});

test('P1 网络失败 → 草稿保持 pending 并计数待重试', async () => {
  const db = makeDb();
  const llm = new FakeLLMAdapter();
  const card = await ingestText({ db, llm, cfg: CFG }, { transcript: '护照放书房抽屉了' });
  expect(card.status).toBe('pending');
  expect(card.retryCount).toBe(1);
  expect(card.lastError).toBeTruthy();
  expect(getCard(db, card.id)?.transcript).toBe('护照放书房抽屉了');
});
