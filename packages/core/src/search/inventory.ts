import type { SqliteDriver } from '../db/driver';
import { countCards, listCards, listCategories } from '../db/repository';
import type { MemoryCard } from '../types';

/**
 * 一次裁决最多列举多少条。
 *
 * **这不是隐私限制**（是否外发由产品决定），而是「注意力与请求体都要有上界」：
 * 清单越长，模型越容易看漏真正相关的那几条，成本也线性上涨。
 * 超出时不是静默截断 —— `text` 末尾会写明截断了，让模型有机会自己说「可能不全」。
 */
export const INVENTORY_LIMIT = 200;

const ENTITY_CHARS = 30;
const PATH_CHARS = 40;
const DESC_CHARS = 60;

export interface Inventory {
  /** 直接拼进 P4 user 消息的清单文本（已含截断说明） */
  text: string;
  /** 全库条数（不含 archived） */
  total: number;
  /** 实际列出的条数 */
  listed: number;
  truncated: boolean;
  /** 与 text 一一对应的卡片；id 合法性只认这份集合，防止模型指到没见过的卡 */
  cards: MemoryCard[];
}

/** 换行会破坏「一行一条」的格式，压成空格 */
function oneLine(value: string | null | undefined, max: number): string {
  if (!value) return '';
  const flat = value.replace(/\s+/g, ' ').trim();
  return flat.length > max ? `${flat.slice(0, max)}…` : flat;
}

/**
 * 把记忆库压成一份「你有什么」的清单，供 P4 逐条裁决。
 *
 * 为什么必须有这一层：推理题（「出国玩该带什么」）的答案**不在库里**，
 * 库里只有「你有什么」，还需要世界知识把两者连起来。
 * 而模型从始至终看不到库存 —— 于是它只能答「没找到」（见 开发交接.md 第十四版诊断）。
 * 这份清单就是补上那个缺失的输入。
 */
export function buildInventory(db: SqliteDriver, opts: { limit?: number } = {}): Inventory {
  const limit = Math.max(0, opts.limit ?? INVENTORY_LIMIT);
  const total = countCards(db);
  const cards = listCards(db, { limit: Math.min(total, limit) });
  const categoryName = new Map(listCategories(db).map((c) => [c.id, c.name]));

  const header = '序号 | id | 实体 | 分类 | 位置 | 简述';
  const rows = cards.map((card, index) => {
    const entity = oneLine(card.entity, ENTITY_CHARS) || '（未命名）';
    const category = card.categoryId ? (categoryName.get(card.categoryId) ?? '未分类') : '未分类';
    const path = oneLine(card.pathNames, PATH_CHARS) || '未记录位置';
    const brief = oneLine(card.desc, DESC_CHARS) || oneLine(card.transcript, DESC_CHARS) || '（无简述）';
    return [String(index + 1), card.id, entity, category, path, brief].join(' | ');
  });

  const truncated = total > cards.length;
  const body = rows.length > 0 ? [header, ...rows].join('\n') : '（记忆库还是空的）';
  const note = truncated
    ? `\n\n（全库共 ${total} 条，此处只列出最近的 ${cards.length} 条 —— 可能不全。` +
      '若清单里没有合适的东西，请在 answer 里说明可能还有未列出的条目。）'
    : '';

  return { text: body + note, total, listed: cards.length, truncated, cards };
}
