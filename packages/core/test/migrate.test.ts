import Database from 'better-sqlite3';
import { expect, test } from 'vitest';
import { currentSchemaVersion, migrate, SCHEMA_VERSION } from '../src/db/migrate';
import { SCHEMA_V1_STATEMENTS } from '../src/db/schema';
import { deleteCategory } from '../src/db/taxonomy';
import { getCard, insertCard, listCategories, listLocations } from '../src/db/repository';
import { nodeDriver } from './node-driver';
import { makeCard, makeDb } from './helpers';

/**
 * 迁移测试。
 *
 * 这里**故意用冻结的 v1 DDL 手搓一个旧库**，而不是复用当前 schema —— 那才是真机上
 * 用户手里那个库的样子。v2 是一次重建（建新表 → 拷贝 → 删旧表 → 改名），
 * 一旦写错，用户打开 App 直接看到「数据库没能打开」，所以每个环节都得钉死：
 *   - 列真的删掉了，而不是留着没数据；
 *   - 该留的数据一列不漏（尤其是 path / steps / tags 这些 JSON 列）；
 *   - cards_fts 重建过，检索不是静默返回空；
 *   - 触发器跟着重建，之后新插入的行也能被搜到；
 *   - PRAGMA foreign_keys 被恢复成 ON（v2 临时关过）。
 */

/** 造一个「用户手机里那个 v1 库」：v1 DDL + v1 预设分类 + 一些真实数据 */
function makeV1Db() {
  const raw = new Database(':memory:');
  const db = nodeDriver(raw);
  for (const s of SCHEMA_V1_STATEMENTS) db.exec(s);
  db.exec(`INSERT INTO categories (id, name, emoji, description, structure_type, sort, is_preset) VALUES
    ('cat_item', '物品存取', '📍', '东西放在哪里的记录', 'item', 0, 1),
    ('cat_todo', '待买补货', '🛒', '要做什么、该买什么', 'todo', 1, 1)`);
  db.exec(`INSERT INTO locations (id, parent_id, name, sort) VALUES
    ('l1', NULL, '主卧', 0), ('l2', 'l1', '衣柜', 1)`);

  insertCard(
    db,
    makeCard({
      id: 'c1',
      entity: '备用手电筒',
      categoryId: 'cat_item',
      pathIds: ['l1', 'l2'],
      pathNames: '主卧/衣柜',
      tags: ['应急', '备用'],
      transcript: '备用手电筒放主卧衣柜顶层',
      desc: '备用手电筒放在主卧衣柜顶层收纳盒里。',
      images: ['files/cards/202609/c1/01.webp'],
      visionAnalyzed: true,
      confidence: 0.86,
      source: 'photo',
      createdAt: '2026-09-01T00:00:00.000Z',
      updatedAt: '2026-09-01T00:00:00.000Z',
    }),
  );
  // 一条把「要删的列」全部填满的卡片：迁移后这些值应当整体消失，而不是被搬到别处
  db.prepare(
    `UPDATE cards SET structure_type = 'item', item_status = 'in_stock', todo_status = NULL,
       procedure_status = NULL, related_person = '老王', due_at = '2026-04-01', cycle = '半年一次'
     WHERE id = 'c1'`,
  ).run();
  db.prepare(
    `INSERT INTO cards (id, status, needs_confirm, needs_organize, structure_type, category_id, entity,
       path_ids, path_names, item_status, todo_status, procedure_status, steps, related_person,
       due_at, cycle, transcript, desc_text, images, audio_path, vision_analyzed, tags, confidence,
       ask, path_suggestion, path_matched, source, retry_count, next_retry_at, last_error,
       created_at, updated_at)
     VALUES ('c2','pending_transcript',1,0,'todo','cat_todo','买牙膏',NULL,NULL,NULL,'open',NULL,
       '[{"text":"看看家里还缺什么","done":false}]',NULL,NULL,NULL,'买牙膏','牙膏快用完了，需要补货。',
       NULL,'files/cards/202609/c2/audio.m4a',NULL,'["日用"]',NULL,'',NULL,NULL,'voice',2,NULL,NULL,
       '2026-09-02T00:00:00.000Z','2026-09-02T00:00:00.000Z')`,
  ).run();
  db.prepare(`INSERT INTO aliases (id, kind, name, card_id) VALUES ('al1','entity','电筒','c1')`).run();
  // v1 的 schema_meta 由 migrate() 自己建，这里补上以模拟「已经跑到 v1」的库
  db.exec('CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
  db.exec(`INSERT INTO schema_meta (key, value) VALUES ('schema_version', '1')`);
  return db;
}

test('v1 → v2：列真的没了，该留的数据一列不漏', () => {
  const db = makeV1Db();
  expect(currentSchemaVersion(db)).toBe(1);

  migrate(db);

  expect(currentSchemaVersion(db)).toBe(SCHEMA_VERSION);

  const cols = (db.prepare('PRAGMA table_info(cards)').all() as { name: string }[]).map((r) => r.name);
  for (const gone of [
    'structure_type',
    'item_status',
    'todo_status',
    'procedure_status',
    'related_person',
    'due_at',
    'cycle',
  ]) {
    expect(cols, `cards 仍残留列 ${gone}`).not.toContain(gone);
  }
  const catCols = (db.prepare('PRAGMA table_info(categories)').all() as { name: string }[]).map(
    (r) => r.name,
  );
  expect(catCols).not.toContain('structure_type');

  // 卡片本身：id / 分类 / 位置 / JSON 列 / 生命周期字段统统不能丢
  const c1 = getCard(db, 'c1')!;
  expect(c1.entity).toBe('备用手电筒');
  expect(c1.categoryId).toBe('cat_item');
  expect(c1.pathIds).toEqual(['l1', 'l2']);
  expect(c1.pathNames).toBe('主卧/衣柜');
  expect(c1.tags).toEqual(['应急', '备用']);
  expect(c1.images).toEqual(['files/cards/202609/c1/01.webp']);
  expect(c1.visionAnalyzed).toBe(true);
  expect(c1.confidence).toBeCloseTo(0.86);
  expect(c1.createdAt).toBe('2026-09-01T00:00:00.000Z');

  const c2 = getCard(db, 'c2')!;
  expect(c2.status).toBe('pending_transcript');
  expect(c2.needsConfirm).toBe(true);
  expect(c2.retryCount).toBe(2);
  expect(c2.source).toBe('voice');
  expect(c2.audioPath).toBe('files/cards/202609/c2/audio.m4a');
  expect(c2.steps).toEqual([{ text: '看看家里还缺什么', done: false }]);

  // 分类、位置、别名：一张表都不能少
  expect(listCategories(db).map((c) => c.name)).toEqual(['物品存取', '待买补货']);
  expect(listLocations(db).map((l) => l.name)).toEqual(['主卧', '衣柜']);
  expect(db.prepare('SELECT name FROM aliases WHERE id = ?').get('al1')).toEqual({ name: '电筒' });

  // v1 的预设分类已存在 ⇒ 不该因为 current!==0 就漏播种，也不该被重复插入
  expect(listCategories(db)).toHaveLength(2);
});

test('v1 → v2：FTS 索引被重建，触发器与 PRAGMA 都回到正常状态', () => {
  const db = makeV1Db();
  migrate(db);

  // 外键在 v2 里临时关过，必须被恢复
  expect(db.prepare('PRAGMA foreign_keys').get()).toEqual({ foreign_keys: 1 });
  expect(db.prepare('PRAGMA foreign_key_check').all()).toEqual([]);

  const trigs = (
    db.prepare("SELECT name FROM sqlite_master WHERE type = 'trigger'").all() as { name: string }[]
  )
    .map((r) => r.name)
    .sort();
  expect(trigs).toEqual(['cards_ad', 'cards_ai', 'cards_au']);

  // 重建前的数据能被搜到（cards_fts 整表重扫过）
  const found = db
    .prepare(
      'SELECT c.id FROM cards_fts JOIN cards c ON c.rowid = cards_fts.rowid WHERE cards_fts MATCH ?',
    )
    .all('手电筒') as { id: string }[];
  expect(found.map((r) => r.id)).toEqual(['c1']);

  // 触发器确实接上了：新插入的行也进索引
  insertCard(
    db,
    makeCard({
      id: 'c3',
      entity: '护照',
      transcript: '护照放书房抽屉',
      desc: '护照放在书房抽屉的文件袋里。',
      tags: ['证件'],
    }),
  );
  const after = db
    .prepare(
      'SELECT c.id FROM cards_fts JOIN cards c ON c.rowid = cards_fts.rowid WHERE cards_fts MATCH ?',
    )
    .all('书房抽屉') as { id: string }[];
  expect(after.map((r) => r.id)).toEqual(['c3']);
});

test('v1 → v2：卡片引用的分类被删掉后，卡片不消失、只是变成无分类', () => {
  const db = makeV1Db();
  migrate(db);
  // 重建后外键关系仍然是活的：deleteCategory 依赖它把引用置空
  expect(deleteCategory(db, 'cat_item', new Date('2026-09-18T00:00:00.000Z'))).toBe(1);
  expect(getCard(db, 'c1')!.entity).toBe('备用手电筒');
  expect(getCard(db, 'c1')!.categoryId).toBeNull();
});

test('全新安装：一次跑到 v2，表结构直接是最终形态且预设分类已播种', () => {
  const db = makeDb();
  expect(currentSchemaVersion(db)).toBe(SCHEMA_VERSION);
  expect(listCategories(db).map((c) => c.name)).toEqual(['物品存取', '待买补货', '流程备忘']);
  // 新库不该有「先建 v1 再重建」留下的痕迹
  expect(listLocations(db)).toEqual([]);
  const leftovers = db
    .prepare("SELECT name FROM sqlite_master WHERE name IN ('cards_new','categories_new')")
    .all();
  expect(leftovers).toEqual([]);
});

test('重复 migrate 是幂等的（每次开库都会跑一遍）', () => {
  const db = makeV1Db();
  migrate(db);
  migrate(db);
  migrate(db);
  expect(currentSchemaVersion(db)).toBe(SCHEMA_VERSION);
  expect(listCategories(db)).toHaveLength(2);
  expect(
    (db.prepare('SELECT COUNT(*) AS n FROM cards').get() as { n: number }).n,
  ).toBe(2);
});
