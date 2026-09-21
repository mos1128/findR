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

/**
 * 参与排序的候选池上界（**不是**外发上界）。
 *
 * 排序必须发生在截断**之前**，所以候选池得比 `INVENTORY_LIMIT` 宽得多。
 * 但「把整库读进内存」也要有个明确的界：真记到上万条时拿最近 2000 条参与排序，
 * 仍然比改动前的「最近 200 条」宽一个数量级。
 */
export const INVENTORY_POOL = 2000;

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

function lower(value: string | null | undefined): string {
  return (value ?? '').toLowerCase();
}

interface CardFields {
  entity: string;
  tags: string;
  category: string;
  path: string;
  body: string;
}

/**
 * 权重：同一个词命中主字段，比命中长描述更有信息量。
 * 「证件」出现在实体名或标签上，基本就是在说这张卡就是证件；
 * 出现在 desc 里则可能只是顺带提一句。
 */
const FIELD_WEIGHTS: { key: keyof CardFields; weight: number }[] = [
  { key: 'entity', weight: 6 },
  { key: 'tags', weight: 4 },
  { key: 'category', weight: 3 },
  { key: 'path', weight: 2 },
  { key: 'body', weight: 1 },
];

function fieldsOf(card: MemoryCard, categoryName: string | null): CardFields {
  return {
    entity: lower(card.entity),
    tags: lower((card.tags ?? []).join(' ')),
    category: lower(categoryName),
    path: lower(card.pathNames),
    body: `${lower(card.desc)} ${lower(card.transcript)}`,
  };
}

/**
 * 把「这次在问什么」拆成能直接做子串比较的短词。
 *
 * 中文没有词边界：`scenario` 与用户原句都是整句，整句拿去子串匹配必然零命中。
 * 所以分成两种处理：**短词原样用**（P2 给的 `aspects` 就是「证件」「洗漱用品」
 * 这类通用名词，命中率最高），**长句按 2 字滑窗切成 n-gram**
 * （「出国旅游需要带什么」切出「出国」「旅游」…，「旅游」才有机会真的碰到某张卡的 desc）。
 */
export function relevanceTerms(inputs: (string | null | undefined)[]): string[] {
  const out = new Set<string>();
  for (const raw of inputs) {
    const text = (raw ?? '')
      .toLowerCase()
      .replace(/[^\p{Script=Han}\p{L}\p{N}]+/gu, ' ')
      .trim();
    if (!text) continue;
    if (text.length <= 6) {
      out.add(text);
      continue;
    }
    for (const word of text.split(' ')) {
      if (!word) continue;
      // 长词本身也留着：万一卡片里原样写过这句话呢（成本为零）
      out.add(word);
      for (let i = 0; i + 2 <= word.length; i++) out.add(word.slice(i, i + 2));
    }
  }
  return [...out];
}

/** 相关性打分：只做本地子串统计，不调模型、不碰网络 */
function scoreCard(card: MemoryCard, categoryName: string | null, terms: string[]): number {
  const fields = fieldsOf(card, categoryName);
  let score = 0;
  for (const term of terms) {
    // 4 字以上的词比 2 字滑窗更有信息量（「洗漱用品」命中 ≫「用品」命中）
    const boost = term.length >= 4 ? 2 : 1;
    for (const { key, weight } of FIELD_WEIGHTS) {
      if (fields[key].includes(term)) score += weight * boost;
    }
  }
  return score;
}

/**
 * 把记忆库压成一份「你有什么」的清单，供 P4 逐条裁决。
 *
 * 为什么必须有这一层：推理题（「出国玩该带什么」）的答案**不在库里**，
 * 库里只有「你有什么」，还需要世界知识把两者连起来。
 * 而模型从始至终看不到库存 —— 于是它只能答「没找到」（见 开发交接.md 第十四版诊断）。
 * 这份清单就是补上那个缺失的输入。
 *
 * 十七版起多了一步：**先排序，再截断**。
 * 原先直接用 `listCards`（`ORDER BY created_at DESC`），把「最近的 200 条」当成了
 * 「最相关的 200 条」—— 而「最近」与「这个场合用不用得上」零相关。
 * 库一大，清单会被一堆无关的新卡占满，而**去年记的护照正好被截在 200 之外**，
 * 那恰恰是这条推理链路存在的唯一理由。
 *
 * 退化情形值得记一笔：若 `terms` 一个词都没碰上（例如 P2 判错了情景），
 * 所有分数都是 0 ⇒ 顺序退化成纯按时间倒序 = 改动前的行为，**不会比原来更差**。
 * 这也正是这里不需要「保底给最近 N 条」配额的原因。
 */
export function buildInventory(
  db: SqliteDriver,
  opts: { limit?: number; terms?: string[] } = {},
): Inventory {
  const limit = Math.max(0, opts.limit ?? INVENTORY_LIMIT);
  const total = countCards(db);
  const pool = total > 0 ? listCards(db, { limit: Math.min(total, INVENTORY_POOL) }) : [];
  const categoryName = new Map(listCategories(db).map((c) => [c.id, c.name]));
  const terms = relevanceTerms(opts.terms ?? []);

  // 同分时保持 `listCards` 给出的「新的在前」；再补 id 兜底，
  // 让同分同时间的顺序**确定**下来，测试才不会偶发。
  const ranked =
    terms.length > 0
      ? pool
          .map((card) => ({
            card,
            score: scoreCard(card, categoryName.get(card.categoryId ?? '') ?? null, terms),
          }))
          .sort(
            (a, b) =>
              b.score - a.score ||
              (a.card.createdAt < b.card.createdAt ? 1 : a.card.createdAt > b.card.createdAt ? -1 : 0) ||
              (a.card.id < b.card.id ? -1 : a.card.id > b.card.id ? 1 : 0),
          )
          .map((entry) => entry.card)
      : pool;

  const cards = ranked.slice(0, limit);

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
    ? `\n\n（全库共 ${total} 条，此处只列出${terms.length > 0 ? '与本次问题最相关的' : '最近的'} ${cards.length} 条` +
      ' —— 可能不全。若清单里没有合适的东西，请在 answer 里说明可能还有未列出的条目。）'
    : '';

  return { text: body + note, total, listed: cards.length, truncated, cards };
}
