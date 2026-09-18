import { expect, test } from 'vitest';
import { ensurePath, listLocations, resolveCategoryId, resolvePath, upsertLocation } from '../src/db/repository';
import { makeDb } from './helpers';

test('分类名匹配容忍 emoji / 空白 / 标点变体（模型回显）', () => {
  const db = makeDb();
  expect(resolveCategoryId(db, '物品存取')).toBe('cat_item');
  expect(resolveCategoryId(db, '📍物品存取')).toBe('cat_item');
  expect(resolveCategoryId(db, ' 物品存取 ')).toBe('cat_item');
  expect(resolveCategoryId(db, '物品存取（item）')).toBe('cat_item');
  expect(resolveCategoryId(db, '不存在的分类')).toBeNull();
});

test('位置树逐级匹配，任一级失配返回 null', () => {
  const db = makeDb();
  upsertLocation(db, { id: 'loc_1', parentId: null, name: '主卧', sort: 0 });
  upsertLocation(db, { id: 'loc_2', parentId: 'loc_1', name: '衣柜', sort: 0 });
  expect(resolvePath(db, ['主卧', '衣柜'])).toEqual({
    ids: ['loc_1', 'loc_2'],
    namesStr: '主卧/衣柜',
  });
  expect(resolvePath(db, ['主卧', '书桌'])).toBeNull();
  expect(resolvePath(db, ['书房'])).toBeNull();
});

test('ensurePath：缺失层级直接新建、已有层级复用', () => {
  const db = makeDb();
  let n = 0;
  const idGen = () => `loc_${++n}`;

  const first = ensurePath(db, ['主卧', '衣柜'], idGen);
  expect(first.created).toEqual(['主卧', '衣柜']);
  expect(first.namesStr).toBe('主卧/衣柜');

  // 第二次完全命中，不该再建节点
  const again = ensurePath(db, ['主卧', '衣柜'], idGen);
  expect(again.created).toEqual([]);
  expect(again.ids).toEqual(first.ids);

  // 只补缺失的最后一层
  const deeper = ensurePath(db, ['主卧', '衣柜', '顶层'], idGen);
  expect(deeper.created).toEqual(['顶层']);
  expect(deeper.ids.slice(0, 2)).toEqual(first.ids);
});

test('ensurePath：同名但父不同不会串到一条链上', () => {
  const db = makeDb();
  let n = 0;
  const idGen = () => `loc_${++n}`;

  const a = ensurePath(db, ['主卧', '衣柜'], idGen);
  const b = ensurePath(db, ['次卧', '衣柜'], idGen);
  expect(b.created).toEqual(['次卧', '衣柜']);
  expect(b.ids[1]).not.toBe(a.ids[1]);
  expect(listLocations(db).map((l) => l.name).sort()).toEqual(['主卧', '次卧', '衣柜', '衣柜']);
});

test('ensurePath：命中位置别名时复用已有节点', () => {
  const db = makeDb();
  let n = 0;
  const idGen = () => `loc_${++n}`;

  const first = ensurePath(db, ['主卧'], idGen);
  db.prepare("INSERT INTO aliases (id, kind, name, location_id) VALUES (?, 'location', ?, ?)").run(
    idGen(),
    '睡房',
    first.ids[0],
  );

  // 「睡房」是「主卧」的别名 ⇒ 复用，而不是又建一个平行的房间
  const viaAlias = ensurePath(db, ['睡房'], idGen);
  expect(viaAlias.created).toEqual([]);
  expect(viaAlias.ids).toEqual(first.ids);
});
