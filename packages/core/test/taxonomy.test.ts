import { expect, test } from 'vitest';
import Database from 'better-sqlite3';
import { migrate } from '../src/db/migrate';
import {
  upsertLocation,
  listCategories,
  listLocations,
  insertCard,
  getCard,
} from '../src/db/repository';
import {
  upsertCategory,
  deleteCategory,
  reorderCategories,
  upsertLocationNode,
  renameLocation,
  deleteLocation,
  refreshPathNames,
  collectHotwords,
} from '../src/db/taxonomy';
import { getSetting, setSetting, listSettings, deleteSetting } from '../src/db/settings';
import { nodeDriver } from './node-driver';
import { makeCard, makeDb } from './helpers';

const NOW = new Date('2026-03-01T00:00:00.000Z');

test('预设分类只在首次建库播种，删掉后重启不复活', () => {
  const raw = new Database(':memory:');
  const db = nodeDriver(raw);
  migrate(db);
  expect(listCategories(db)).toHaveLength(3);

  deleteCategory(db, 'cat_item', NOW);
  expect(listCategories(db).map((c) => c.id)).not.toContain('cat_item');

  // 模拟重启：同一个库再跑一次 migrate
  migrate(db);
  expect(listCategories(db).map((c) => c.id)).not.toContain('cat_item');
});

test('删除分类会把引用它的卡片置空而不是留下悬空引用', () => {
  const db = makeDb();
  insertCard(db, makeCard({ id: 'c1', categoryId: 'cat_todo' }));
  const affected = deleteCategory(db, 'cat_todo', NOW);
  expect(affected).toBe(1);
  expect(getCard(db, 'c1')!.categoryId).toBeNull();
});

test('分类重名会被 UNIQUE 约束挡住（P1 路由是按名字匹配的）', () => {
  const db = makeDb();
  expect(() =>
    upsertCategory(db, {
      id: 'cat_custom',
      name: '物品存取',
      emoji: null,
      description: null,
      sort: 9,
      isPreset: false,
    }),
  ).toThrow();
});

test('分类可新增、改名与重排', () => {
  const db = makeDb();
  upsertCategory(db, {
    id: 'cat_custom',
    name: '装修记录',
    emoji: '🔨',
    description: '装修期间临时堆放',
    sort: 3,
    isPreset: false,
  });
  expect(listCategories(db).map((c) => c.name)).toContain('装修记录');

  upsertCategory(db, {
    id: 'cat_custom',
    name: '装修',
    emoji: '🔨',
    description: null,
    sort: 3,
    isPreset: false,
  });
  const updated = listCategories(db).find((c) => c.id === 'cat_custom')!;
  expect(updated.name).toBe('装修');
  expect(updated.description).toBeNull();

  reorderCategories(db, ['cat_custom', 'cat_item', 'cat_todo', 'cat_procedure']);
  expect(listCategories(db).map((c) => c.id)).toEqual([
    'cat_custom',
    'cat_item',
    'cat_todo',
    'cat_procedure',
  ]);
});

test('同一父节点下位置重名被唯一索引挡住（防路径分裂）', () => {
  const db = makeDb();
  upsertLocation(db, { id: 'l1', parentId: null, name: '主卧', sort: 0 });
  upsertLocation(db, { id: 'l2', parentId: null, name: '主卧室', sort: 1 });
  // 不同名可以共存
  expect(listLocations(db)).toHaveLength(2);
  // 重名（同父）被忽略
  upsertLocation(db, { id: 'l3', parentId: null, name: '主卧', sort: 2 });
  expect(listLocations(db).map((l) => l.id)).toEqual(['l1', 'l2']);
});

test('位置可改名、可挂到父节点下', () => {
  const db = makeDb();
  upsertLocationNode(db, { id: 'l1', parentId: null, name: '主卧', sort: 0 });
  upsertLocationNode(db, { id: 'l2', parentId: null, name: '衣柜', sort: 1 });
  renameLocation(db, 'l2', '衣帽间');
  upsertLocationNode(db, { id: 'l2', parentId: 'l1', name: '衣帽间', sort: 0 });

  const l2 = listLocations(db).find((l) => l.id === 'l2')!;
  expect(l2.name).toBe('衣帽间');
  expect(l2.parentId).toBe('l1');
});

test('有子节点或被卡片引用的位置拒绝删除', () => {
  const db = makeDb();
  upsertLocation(db, { id: 'l1', parentId: null, name: '主卧', sort: 0 });
  upsertLocation(db, { id: 'l2', parentId: 'l1', name: '衣柜', sort: 0 });
  insertCard(
    db,
    makeCard({ id: 'c1', pathIds: ['l1', 'l2'], pathNames: '主卧/衣柜' }),
  );

  const withChildren = deleteLocation(db, 'l1');
  expect(withChildren).toEqual({ ok: false, reason: 'has_children', count: 1 });

  const referenced = deleteLocation(db, 'l2');
  expect(referenced).toEqual({ ok: false, reason: 'referenced_by_cards', count: 1 });

  // 未被引用且无子节点的可以删
  upsertLocation(db, { id: 'l3', parentId: null, name: '书房', sort: 2 });
  expect(deleteLocation(db, 'l3')).toEqual({ ok: true });
});

test('位置改名后 refreshPathNames 让冗余串跟上（M3「改名后检索仍命中」）', () => {
  const db = makeDb();
  upsertLocation(db, { id: 'l1', parentId: null, name: '主卧', sort: 0 });
  upsertLocation(db, { id: 'l2', parentId: 'l1', name: '衣柜', sort: 0 });
  insertCard(db, makeCard({ id: 'c1', pathIds: ['l1', 'l2'], pathNames: '主卧/衣柜' }));

  renameLocation(db, 'l2', '衣帽间');
  expect(refreshPathNames(db, NOW)).toBe(1);
  expect(getCard(db, 'c1')!.pathNames).toBe('主卧/衣帽间');

  // 没有变化时不重复写
  expect(refreshPathNames(db, NOW)).toBe(0);
});

test('refreshPathNames 跳过节点已缺失的卡片，不写出空洞', () => {
  const db = makeDb();
  upsertLocation(db, { id: 'l1', parentId: null, name: '主卧', sort: 0 });
  insertCard(db, makeCard({ id: 'c1', pathIds: ['l1', 'gone'], pathNames: '主卧/旧名' }));
  expect(refreshPathNames(db, NOW)).toBe(0);
  expect(getCard(db, 'c1')!.pathNames).toBe('主卧/旧名');
});

test('ASR 热词取一二级位置名 + 高频实体', () => {
  const db = makeDb();
  upsertLocation(db, { id: 'l1', parentId: null, name: '主卧', sort: 0 });
  upsertLocation(db, { id: 'l2', parentId: 'l1', name: '衣柜', sort: 0 });
  upsertLocation(db, { id: 'l3', parentId: 'l2', name: '顶层', sort: 0 });
  insertCard(db, makeCard({ id: 'c1', entity: '手电筒' }));
  insertCard(db, makeCard({ id: 'c2', entity: '手电筒' }));
  insertCard(db, makeCard({ id: 'c3', entity: '猫砂' }));

  const words = collectHotwords(db);
  expect(words).toContain('主卧');
  expect(words).toContain('衣柜');
  // 三级容器不进热词
  expect(words).not.toContain('顶层');
  expect(words.indexOf('手电筒')).toBeLessThan(words.indexOf('猫砂'));
});

test('settings 读写为 JSON，坏值不炸', () => {
  const db = makeDb();
  setSetting(db, 'llm', { model: 'claude-opus-5', authStyle: 'bearer' });
  expect(getSetting<{ model: string }>(db, 'llm')?.model).toBe('claude-opus-5');
  expect(getSetting(db, 'missing')).toBeNull();

  // 覆盖写
  setSetting(db, 'llm', { model: 'gpt-4o' });
  expect(getSetting<{ model: string }>(db, 'llm')?.model).toBe('gpt-4o');

  db.prepare("INSERT INTO settings (key, value) VALUES ('broken', 'not json')").run();
  expect(getSetting(db, 'broken')).toBeNull();
  expect(listSettings(db).broken).toBeUndefined();

  deleteSetting(db, 'llm');
  expect(getSetting(db, 'llm')).toBeNull();
});

test('外键约束在 node 测试驱动里同样生效（与设备端对齐）', () => {
  const db = makeDb();
  expect(() =>
    insertCard(db, makeCard({ id: 'c_bad', categoryId: 'cat_does_not_exist' })),
  ).toThrow();
});
