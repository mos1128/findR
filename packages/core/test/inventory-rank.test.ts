import { expect, test } from 'vitest';
import { insertCard } from '../src/db/repository';
import { buildInventory, relevanceTerms } from '../src/search/inventory';
import { makeCard, makeDb } from './helpers';

/**
 * 库存清单的**排序**（第十七版）。
 *
 * 起因：用户问「物品加得很多以后，岂不是一次性把一大堆物品的信息传给大模型」。
 * 定位题不受影响（它只发命中片段），但推理题的清单确实随库增长 ——
 * 而查下来真正的毛病不是 token 上界，是**排序依据**：
 * 原来走 `listCards`（`ORDER BY created_at DESC`），把「最近的 200 条」当成了
 * 「最相关的 200 条」。库一大，清单就被无关的新卡占满，
 * **去年记的护照正好被截在 200 之外** —— 那恰恰是这条链路存在的唯一理由。
 */

const PASSPORT = makeCard({
  id: 'passport',
  entity: '护照',
  desc: '因私护照放在主卧床头柜第二层抽屉，和户口本放在一起。',
  tags: ['证件', '出行'],
  pathNames: '主卧/床头柜',
  categoryId: 'cat_item',
  createdAt: '2025-01-01T00:00:00.000Z',
});

/** 严格递增的时间戳：让「时间倒序」这件事在测试里是确定的 */
function at(index: number): string {
  return new Date(Date.UTC(2026, 5, 1, 0, index)).toISOString();
}

/** 一批与「出国玩该带什么」毫无关系的卡，且都比护照新 */
function seedNoise(db: ReturnType<typeof makeDb>, count: number) {
  for (let i = 0; i < count; i++) {
    insertCard(db, makeCard({ id: `noise-${String(i).padStart(3, '0')}`, entity: `杂物${i}`, createdAt: at(i) }));
  }
}

const ADVISE_TERMS = ['证件', '洗漱用品', '电子产品', '出国旅游需要随身携带的物品', '我去国外玩应该会用到哪些东西'];

test('排序：库大了以后，最相关的旧卡不会被无关的新卡挤出清单', () => {
  const db = makeDb();
  insertCard(db, PASSPORT);
  seedNoise(db, 260);

  // 改动前：这里拿到的是「最近 200 条」= noise-060 ~ noise-259，护照被截掉
  const inv = buildInventory(db, { terms: ADVISE_TERMS });

  expect(inv.total).toBe(261);
  expect(inv.listed).toBe(200);
  expect(inv.truncated).toBe(true);
  expect(inv.cards.some((c) => c.id === 'passport')).toBe(true);
  // 命中了标签「证件」，相关度最高 ⇒ 排在第一条（模型最先读到）
  expect(inv.cards[0].id).toBe('passport');
});

test('排序：命中主字段的排在「只在描述里提一句」的前面', () => {
  const db = makeDb();
  insertCard(
    db,
    makeCard({
      id: 'by-entity',
      entity: '出国证件收纳袋',
      tags: ['证件'],
      createdAt: '2025-01-01T00:00:00.000Z',
    }),
  );
  insertCard(
    db,
    makeCard({
      id: 'by-desc',
      entity: '鞋盒',
      desc: '鞋盒里塞着一些旧证件复印件和过期的名片。',
      createdAt: '2026-06-01T00:00:00.000Z',
    }),
  );

  const inv = buildInventory(db, { terms: ['证件'], limit: 1 });
  expect(inv.cards.map((c) => c.id)).toEqual(['by-entity']);
});

test('排序：不传 terms 时保持原行为（按时间倒序，新的在前）', () => {
  const db = makeDb();
  insertCard(db, makeCard({ id: 'old', entity: '旧', createdAt: at(0) }));
  insertCard(db, makeCard({ id: 'new', entity: '新', createdAt: at(5) }));

  const inv = buildInventory(db);
  expect(inv.cards.map((c) => c.id)).toEqual(['new', 'old']);
  expect(inv.text).not.toContain('最相关');
});

test('排序：提示词一个词都没碰上时，退回按时间倒序（不会比原来更差）', () => {
  const db = makeDb();
  insertCard(db, makeCard({ id: 'old', entity: '旧', createdAt: at(0) }));
  insertCard(db, makeCard({ id: 'new', entity: '新', createdAt: at(5) }));

  const inv = buildInventory(db, { terms: ['zzz-完全不相干的词汇-qqq'] });
  expect(inv.cards.map((c) => c.id)).toEqual(['new', 'old']);
});

test('排序：截断说明写的是「最相关」而不是「最近」', () => {
  const db = makeDb();
  insertCard(db, PASSPORT);
  seedNoise(db, 10);

  const ranked = buildInventory(db, { terms: ['证件'], limit: 5 });
  expect(ranked.text).toContain('全库共 11 条');
  expect(ranked.text).toContain('与本次问题最相关的 5 条');
  expect(ranked.text).toContain('可能不全');

  const plain = buildInventory(db, { limit: 5 });
  expect(plain.text).toContain('最近的 5 条');
});

test('提示词拆分：短词原样用，长句切成 2 字滑窗', () => {
  const terms = relevanceTerms(['洗漱用品', '出国旅游需要带什么', null, '  ']);
  expect(terms).toContain('洗漱用品');
  expect(terms).toContain('旅游');
  expect(terms).toContain('出国');
  // 空值与纯空白不该混进词表
  expect(terms).not.toContain('');
});
