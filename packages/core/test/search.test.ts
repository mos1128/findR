import { expect, test } from 'vitest';
import { executeSearch, insertCard } from '../src/db/repository';
import type { P2Output } from '../src/parse';
import type { BuiltSearch } from '../src/search/builder';
import { buildRawSearch, buildSearch, escapeLike, quoteFts, splitTerms } from '../src/search/builder';
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

test('buildRawSearch：整句按标点切分', () => {
  const b = buildRawSearch('我那件厚外套，放哪了？');
  expect(b.ftsExpr).toContain('厚外套');
  expect(b.ftsExpr).toContain('放哪了');
});
