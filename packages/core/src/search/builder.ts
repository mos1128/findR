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

/** 兜底路径：P2 失败/无网时，原始 query 按标点粗切分后直查（无同义词扩展） */
export function buildRawSearch(query: string): BuiltSearch {
  const segments = query
    .split(/[\s，。？！,.?!、；;：:"'“”‘’()（）]+/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  const { fts, like } = splitTerms(segments.length > 0 ? segments : [query]);
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
