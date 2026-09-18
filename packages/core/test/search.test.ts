import { expect, test } from 'vitest';
import { executeSearch, insertCard } from '../src/db/repository';
import type { P2Output } from '../src/parse';
import type { BuiltSearch } from '../src/search/builder';
import { buildRawSearch, buildSearch, escapeLike, quoteFts, splitTerms } from '../src/search/builder';
import { searchCards } from '../src/search/service';
import { makeCard, makeDb } from './helpers';

const EMPTY: BuiltSearch = {
  ftsExpr: null,
  likeTerms: [],
  matchMode: 'any',
  categoryId: null,
  pathPrefixLike: null,
  sinceIso: null,
  limit: 50,
};

test('splitTerms：<3 字词降级 LIKE、去重去空白', () => {
  const r = splitTerms(['厚外套', '护照', ' 护照 ', '']);
  expect(r.fts).toEqual(['厚外套']);
  expect(r.like).toEqual(['护照']);
});

test('quoteFts / escapeLike 转义', () => {
  expect(quoteFts('a"b')).toBe('"a""b"');
  expect(escapeLike('50%_x')).toBe('50\\%\\_x');
});

test('buildSearch：unknown 或空关键词返回 null（不盲查）', () => {
  const base: P2Output = {
    intent: 'unknown',
    keywords: [],
    synonyms: [],
    category: null,
    path_prefix: null,
    time_hint: null,
    match_mode: 'any',
    normalized_query: null,
  };
  expect(buildSearch({ p2: base, resolveCategoryId: () => null })).toBeNull();
  expect(
    buildSearch({ p2: { ...base, intent: 'find_item' }, resolveCategoryId: () => null }),
  ).toBeNull();
});

test('FTS 排序：desc 命中优于 transcript 命中（bm25 权重）', () => {
  const db = makeDb();
  insertCard(db, makeCard({ id: 'desc-hit', entity: 'A卡', desc: '羽绒服收在主卧衣柜', createdAt: '2026-01-01T00:00:00.000Z' }));
  insertCard(db, makeCard({ id: 'transcript-hit', entity: 'B卡', transcript: '羽绒服放这里了', createdAt: '2026-06-01T00:00:00.000Z' }));
  const hits = executeSearch(db, { ...EMPTY, ftsExpr: '"羽绒服"' });
  expect(hits.map((c) => c.id)).toEqual(['desc-hit', 'transcript-hit']);
});

test('两字词通过 LIKE 降级命中（trigram 限制）', () => {
  const db = makeDb();
  insertCard(db, makeCard({ id: 'passport', entity: '护照', desc: '护照放在书房抽屉' }));
  const hits = executeSearch(db, { ...EMPTY, likeTerms: ['护照'] });
  expect(hits.map((c) => c.id)).toEqual(['passport']);
});

test('archived 卡不进检索结果', () => {
  const db = makeDb();
  insertCard(db, makeCard({ id: 'gone', entity: '旧物', desc: '羽绒服', status: 'archived' }));
  const hits = executeSearch(db, { ...EMPTY, ftsExpr: '"羽绒服"' });
  expect(hits).toEqual([]);
});

test('buildRawSearch：整句先按标点切，再丢掉虚词', () => {
  const b = buildRawSearch('我那件厚外套，放哪了？');
  expect(b.ftsExpr).toContain('我那件厚外套');
  // 「了」是虚词：留着的话「放哪了」会变成一句无从匹配的短语，去掉后才可能命中卡片原文
  expect(b.ftsExpr ?? '').not.toContain('放哪了');
  expect(b.likeTerms).toContain('放哪');
});

test('未配模型时字面检索照常可用，不再抛错', async () => {
  const db = makeDb();
  insertCard(db, makeCard({ id: 'passport', entity: '护照', desc: '护照放在书房抽屉' }));

  // 显式 null 与整个字段缺失都要能用 —— 与「配了模型但端点不通」殊途同归
  const explicit = await searchCards({ db, llm: null, cfg: null }, '护照');
  expect(explicit.cards.map((c) => c.id)).toEqual(['passport']);
  expect(explicit.usedFallback).toBe(true);

  const omitted = await searchCards({ db }, '护照');
  expect(omitted.cards.map((c) => c.id)).toEqual(['passport']);
  expect(omitted.usedFallback).toBe(true);
});

test('未配模型时中文整句也能搜到（虚词切掉后落到实词上）', async () => {
  const db = makeDb();
  insertCard(db, makeCard({ id: 'passport', entity: '护照', desc: '护照放在书房抽屉' }));
  // 旧实现把整句当一个 8 字短语 ⇒ 连续子串对不上 ⇒ 0 条，离线搜索形同虚设
  const res = await searchCards({ db }, '我的护照在哪');
  expect(res.cards.map((c) => c.id)).toEqual(['passport']);
});
