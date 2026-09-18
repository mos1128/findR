import { expect, test } from 'vitest';
import { resolveCategoryId, resolvePath, upsertLocation } from '../src/db/repository';
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
