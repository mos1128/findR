import type { P2Output } from '../parse';

export interface BuiltSearch {
  ftsExpr: string | null;
  likeTerms: string[];
  matchMode: 'any' | 'all';
  categoryId: string | null;
  pathPrefixLike: string | null;
  sinceIso: string | null;
  limit: number;
}

export function quoteFts(term: string): string {
  return `"${term.replace(/"/g, '""')}"`;
}

export function escapeLike(term: string): string {
  return term.replace(/[\\%_]/g, (m) => `\\${m}`);
}

/** trigram 硬限制：<3 字的词（护照、猫砂）FTS 匹配不到，降级 LIKE */
export function splitTerms(terms: string[]): { fts: string[]; like: string[] } {
  const clean = [...new Set(terms.map((t) => t.trim()).filter((t) => t.length > 0))];
  return {
    fts: clean.filter((t) => t.length >= 3),
    like: clean.filter((t) => t.length < 3),
  };
}

function timeHintToSince(hint: string | null | undefined, now: Date): string | null {
  const ms: Record<string, number> = {
    recent: 3 * 864e5,
    this_week: 7 * 864e5,
    this_month: 30 * 864e5,
    this_year: 365 * 864e5,
  };
  if (!hint || !(hint in ms)) return null;
  return new Date(now.getTime() - ms[hint]).toISOString();
}

/** P2 结果 → SQL 输入；intent=unknown 或关键词为空时返回 null（不盲查，UI 提示换说法） */
export function buildSearch(input: {
  p2: P2Output;
  resolveCategoryId: (name: string) => string | null;
  now?: Date;
}): BuiltSearch | null {
  const p2 = input.p2;
  if (p2.intent === 'unknown' || p2.keywords.length === 0) return null;
  const { fts, like } = splitTerms([...p2.keywords, ...p2.synonyms]);
  const ftsExpr =
    fts.length > 0 ? fts.map(quoteFts).join(p2.match_mode === 'all' ? ' AND ' : ' OR ') : null;
  const categoryId = p2.category ? input.resolveCategoryId(p2.category) : null;
  const pathPrefixLike =
    p2.path_prefix && p2.path_prefix.length > 0
      ? escapeLike(p2.path_prefix.join('/')) + '%'
      : null;
  return {
    ftsExpr,
    likeTerms: like,
    matchMode: p2.match_mode,
    categoryId,
    pathPrefixLike,
    sinceIso: timeHintToSince(p2.time_hint, input.now ?? new Date()),
    limit: 50,
  };
}

/**
 * 兜底检索要丢弃的虚词 / 疑问词。
 *
 * 中文没有词边界，只按标点切分的话整句会被当成一个长短语：「我的护照在哪」变成
 * 一个 8 字 FTS 短语，而卡片里存的是「护照放在主卧抽屉」—— 连续子串对不上，必然 0 条。
 * 于是「离线也能搜」变成了「离线搜不到」，这是离线可用性的头号杀手。
 *
 * 按这些词切开后剩下的是实词（「护照」），才可能命中卡片。
 * 只收多字词和少数绝对安全的单字；单字的「在 / 放 / 找」刻意不收 ——
 * 它们会切坏「现在」「放心」「寻找」这类正常词，得不偿失。
 */
const RAW_STOPWORDS = [
  '什么',
  '怎么',
  '为什么',
  '哪去了',
  '哪里',
  '哪个',
  '哪儿',
  '在哪',
  '放在',
  '放到',
  '收在',
  '请问',
  '帮我',
  '帮忙',
  '一下',
  '我的',
  '你的',
  '他的',
  '她的',
  '记得',
  '上次',
  '那个',
  '这个',
  '有没有',
  '没有',
  '了吗',
  '是不是',
  '的',
  '了',
  '吗',
  '呢',
  '吧',
  '啊',
];

/** 按停用词把一段文本切成实词片段；切不动就原样返回 */
function cutByStopwords(segment: string): string[] {
  let parts = [segment];
  for (const w of RAW_STOPWORDS) {
    if (!parts.some((p) => p.includes(w))) continue;
    const next: string[] = [];
    for (const p of parts) next.push(...(p.includes(w) ? p.split(w) : [p]));
    parts = next;
  }
  return parts.map((s) => s.trim()).filter((s) => s.length > 0);
}

/**
 * 兜底路径：P2 失败/无网/未配模型时，原始 query 直查（无同义词扩展、无分类位置时间约束）。
 * 切词分两步：先按标点，再按虚词 —— 后者是为了让中文整句也能落到实词上。
 */
export function buildRawSearch(query: string): BuiltSearch {
  const segments = query
    .split(/[\s，。？！,.?!、；;：:"'“”‘’()（）]+/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);

  const base = segments.length > 0 ? segments : [query];
  const refined = base.flatMap(cutByStopwords);
  // 整句都是虚词（如「在哪」）时会切空，此时退回原串，宁可 0 条也别查空条件
  const terms = refined.length > 0 ? refined : base;

  const { fts, like } = splitTerms(terms);
  return {
    ftsExpr: fts.length > 0 ? fts.map(quoteFts).join(' OR ') : null,
    likeTerms: like,
    matchMode: 'any',
    categoryId: null,
    pathPrefixLike: null,
    sinceIso: null,
    limit: 50,
  };
}
