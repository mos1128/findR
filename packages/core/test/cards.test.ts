import { expect, test } from 'vitest';
import {
  listCards,
  countCards,
  updateCardFields,
  clearNeedsOrganize,
  setCardStatus,
  setVisionAnalyzed,
  setTranscript,
  deleteCard,
  listQueueCards,
  resetTranscriptRetries,
  insertCard,
  getCard,
  RETRY_BACKOFF_MS,
  MAX_AUTO_RETRY,
} from '../src/db/repository';
import { makeCard, makeDb } from './helpers';

const NOW = new Date('2026-03-01T00:00:00.000Z');

test('listCards 默认排除归档，但草稿三态恒定可见', () => {
  const db = makeDb();
  insertCard(db, makeCard({ id: 'c_active', status: 'active' }));
  insertCard(db, makeCard({ id: 'c_pending', status: 'pending' }));
  insertCard(db, makeCard({ id: 'c_ptr', status: 'pending_transcript' }));
  insertCard(db, makeCard({ id: 'c_archived', status: 'archived' }));

  const ids = listCards(db).map((c) => c.id);
  expect(ids).toContain('c_active');
  expect(ids).toContain('c_pending');
  expect(ids).toContain('c_ptr');
  expect(ids).not.toContain('c_archived');
  expect(countCards(db)).toBe(3);

  const withArchived = listCards(db, { includeArchived: true }).map((c) => c.id);
  expect(withArchived).toContain('c_archived');
});

test('listCards 支持单类筛选与分页', () => {
  const db = makeDb();
  for (let i = 0; i < 5; i++) {
    insertCard(
      db,
      makeCard({
        id: `c${i}`,
        categoryId: i < 2 ? 'cat_todo' : 'cat_item',
        createdAt: `2026-03-0${i + 1}T00:00:00.000Z`,
      }),
    );
  }
  expect(listCards(db, { categoryId: 'cat_todo' }).map((c) => c.id)).toEqual(['c1', 'c0']);
  expect(countCards(db, { categoryId: 'cat_item' })).toBe(3);
  const page = listCards(db, { limit: 2, offset: 2 }).map((c) => c.id);
  expect(page).toHaveLength(2);
});

test('updateCardFields 只写传入的键，JSON 列序列化，恒定刷新 updated_at', () => {
  const db = makeDb();
  insertCard(db, makeCard({ id: 'c1', entity: '旧名', tags: ['a'] }));

  updateCardFields(db, 'c1', { entity: '新名', tags: ['x', 'y'], steps: [{ text: '第一步', done: true }] }, NOW);
  const card = getCard(db, 'c1')!;
  expect(card.entity).toBe('新名');
  expect(card.tags).toEqual(['x', 'y']);
  expect(card.steps).toEqual([{ text: '第一步', done: true }]);
  expect(card.updatedAt).toBe(NOW.toISOString());
  // 未传入的字段保持不动
  expect(card.status).toBe('active');

  // 显式传 null 才会清空
  updateCardFields(db, 'c1', { tags: null }, NOW);
  expect(getCard(db, 'c1')!.tags).toBeNull();
});

test('卡片只保留分类这一个组织维度（结构类型与业务状态已从产品移除）', () => {
  const db = makeDb();
  insertCard(db, makeCard({ id: 'c1', categoryId: 'cat_todo' }));
  updateCardFields(db, 'c1', { categoryId: 'cat_procedure' }, NOW);
  const card = getCard(db, 'c1')!;
  expect(card.categoryId).toBe('cat_procedure');
  // 物理列也必须真的不存在了，否则备份/检索会读到幽灵数据
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
});

test('待整理标志的清除动作', () => {
  const db = makeDb();
  insertCard(db, makeCard({ id: 'c1', needsOrganize: true }));
  clearNeedsOrganize(db, 'c1', NOW);
  expect(getCard(db, 'c1')!.needsOrganize).toBe(false);
});

test('vision_analyzed 三态可写', () => {
  const db = makeDb();
  insertCard(db, makeCard({ id: 'c1', visionAnalyzed: false, images: ['files/a.webp'] }));
  setVisionAnalyzed(db, 'c1', true, NOW);
  expect(getCard(db, 'c1')!.visionAnalyzed).toBe(true);
});

test('归档与恢复', () => {
  const db = makeDb();
  insertCard(db, makeCard({ id: 'c1', status: 'active' }));
  setCardStatus(db, 'c1', 'archived', NOW);
  expect(listCards(db).map((c) => c.id)).not.toContain('c1');
  setCardStatus(db, 'c1', 'active', NOW);
  expect(listCards(db).map((c) => c.id)).toContain('c1');
});

test('setTranscript 把待转写推进到待解析并清掉补问', () => {
  const db = makeDb();
  insertCard(db, makeCard({ id: 'c1', status: 'pending_transcript', ask: '这是哪个房间？' }));
  setTranscript(db, 'c1', '手电筒放主卧衣柜', NOW);
  const card = getCard(db, 'c1')!;
  expect(card.transcript).toBe('手电筒放主卧衣柜');
  expect(card.status).toBe('pending');
  expect(card.ask).toBeNull();
});

test('setTranscript 不会把已入库的卡片退回待解析', () => {
  const db = makeDb();
  insertCard(db, makeCard({ id: 'c1', status: 'active', transcript: '旧文本' }));
  setTranscript(db, 'c1', '新文本', NOW);
  expect(getCard(db, 'c1')!.status).toBe('active');
});

test('deleteCard 连带清掉别名', () => {
  const db = makeDb();
  insertCard(db, makeCard({ id: 'c1' }));
  db.prepare("INSERT INTO aliases (id, kind, name, card_id) VALUES (?, 'entity', ?, ?)").run(
    'al1',
    '手电',
    'c1',
  );
  deleteCard(db, 'c1');
  expect(getCard(db, 'c1')).toBeUndefined();
  expect(db.prepare('SELECT COUNT(*) AS n FROM aliases').get()).toEqual({ n: 0 });
});

test('队列遵守退避时间与自动重试上限', () => {
  const db = makeDb();
  insertCard(db, makeCard({ id: 'ready', status: 'pending' }));
  insertCard(
    db,
    makeCard({ id: 'backoff', status: 'pending', nextRetryAt: '2026-03-02T00:00:00.000Z' }),
  );
  insertCard(db, makeCard({ id: 'exhausted', status: 'pending', retryCount: MAX_AUTO_RETRY }));
  insertCard(db, makeCard({ id: 'done', status: 'active' }));

  const ids = listQueueCards(db, NOW).map((c) => c.id);
  expect(ids).toEqual(['ready']);
});

test('resetTranscriptRetries 无视退避与上限（批量补转写）', () => {
  const db = makeDb();
  insertCard(
    db,
    makeCard({
      id: 'p1',
      status: 'pending_transcript',
      retryCount: MAX_AUTO_RETRY,
      nextRetryAt: '2026-04-01T00:00:00.000Z',
      lastError: '网络失败',
    }),
  );
  insertCard(db, makeCard({ id: 'p2', status: 'pending' }));

  expect(resetTranscriptRetries(db, NOW)).toBe(1);
  // p1 此前已耗尽重试且未到退避时间，重置后重新可被队列捞起
  const queued = listQueueCards(db, NOW).map((c) => c.id);
  expect(queued).toContain('p1');
  expect(queued).toContain('p2');
  expect(getCard(db, 'p1')!.lastError).toBeNull();
  expect(getCard(db, 'p1')!.retryCount).toBe(0);
  expect(getCard(db, 'p1')!.nextRetryAt).toBeNull();
});

test('退避序列是 1min→5min→30min→2h→次日，共 5 档', () => {
  expect(RETRY_BACKOFF_MS).toEqual([60_000, 300_000, 1_800_000, 7_200_000, 86_400_000]);
  expect(MAX_AUTO_RETRY).toBe(5);
});
