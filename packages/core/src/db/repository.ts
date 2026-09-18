import type {
  CardStatus,
  Category,
  LocationNode,
  MemoryCard,
  SourceKind,
  StepItem,
  StructureType,
} from '../types';
import type { SqliteDriver } from './driver';
import { escapeLike } from '../search/builder';
import type { BuiltSearch } from '../search/builder';

const CARD_COLS =
  'id, status, needs_confirm, needs_organize, structure_type, category_id, entity, path_ids, path_names, item_status, todo_status, procedure_status, steps, related_person, due_at, cycle, transcript, desc_text, images, audio_path, vision_analyzed, tags, confidence, ask, path_suggestion, path_matched, source, retry_count, next_retry_at, last_error, created_at, updated_at';

/** 退避序列：1min → 5min → 30min → 2h → 次日；到上限后只留手动重试 / 批量补转写 */
export const RETRY_BACKOFF_MS: readonly number[] = [
  60_000, 300_000, 1_800_000, 7_200_000, 86_400_000,
];
export const MAX_AUTO_RETRY = RETRY_BACKOFF_MS.length;

/** 传入本次失败后的 retry_count（已自增），返回下次可自动重试的延后毫秒数 */
export function computeBackoffMs(retryCount: number): number {
  const idx = Math.min(Math.max(retryCount, 1), RETRY_BACKOFF_MS.length) - 1;
  return RETRY_BACKOFF_MS[idx];
}

export function makeId(): string {
  const c = (globalThis as { crypto?: { randomUUID?: () => string } }).crypto;
  if (c && typeof c.randomUUID === 'function') return c.randomUUID();
  return 'id-' + Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
}

function toJson(v: unknown[] | null): string | null {
  return v == null ? null : JSON.stringify(v);
}

function parseJsonArray<T>(v: unknown): T[] | null {
  if (v == null) return null;
  try {
    return JSON.parse(String(v)) as T[];
  } catch {
    return null;
  }
}

export function rowToCard(row: Record<string, unknown>): MemoryCard {
  return {
    id: String(row.id),
    status: row.status as CardStatus,
    needsConfirm: row.needs_confirm === 1,
    needsOrganize: row.needs_organize === 1,
    structureType: (row.structure_type as StructureType | null) ?? null,
    categoryId: (row.category_id as string | null) ?? null,
    entity: (row.entity as string | null) ?? null,
    pathIds: parseJsonArray<string>(row.path_ids),
    pathNames: (row.path_names as string | null) ?? null,
    itemStatus: (row.item_status as MemoryCard['itemStatus']) ?? null,
    todoStatus: (row.todo_status as MemoryCard['todoStatus']) ?? null,
    procedureStatus: (row.procedure_status as MemoryCard['procedureStatus']) ?? null,
    steps: parseJsonArray<StepItem>(row.steps),
    relatedPerson: (row.related_person as string | null) ?? null,
    dueAt: (row.due_at as string | null) ?? null,
    cycle: (row.cycle as string | null) ?? null,
    transcript: (row.transcript as string | null) ?? null,
    desc: (row.desc_text as string | null) ?? null,
    images: parseJsonArray<string>(row.images),
    audioPath: (row.audio_path as string | null) ?? null,
    visionAnalyzed: row.vision_analyzed == null ? null : row.vision_analyzed === 1,
    tags: parseJsonArray<string>(row.tags),
    confidence: row.confidence == null ? null : Number(row.confidence),
    ask: (row.ask as string | null) ?? null,
    pathSuggestion: (row.path_suggestion as string | null) ?? null,
    pathMatched: row.path_matched == null ? null : row.path_matched === 1,
    source: row.source as SourceKind,
    retryCount: Number(row.retry_count ?? 0),
    nextRetryAt: (row.next_retry_at as string | null) ?? null,
    lastError: (row.last_error as string | null) ?? null,
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
  };
}

export function insertCard(db: SqliteDriver, card: MemoryCard): void {
  db.prepare(
    `INSERT INTO cards (${CARD_COLS}) VALUES (${CARD_COLS.split(',').map(() => '?').join(',')})`,
  ).run(
    card.id,
    card.status,
    card.needsConfirm ? 1 : 0,
    card.needsOrganize ? 1 : 0,
    card.structureType,
    card.categoryId,
    card.entity,
    toJson(card.pathIds),
    card.pathNames,
    card.itemStatus,
    card.todoStatus,
    card.procedureStatus,
    toJson(card.steps),
    card.relatedPerson,
    card.dueAt,
    card.cycle,
    card.transcript,
    card.desc,
    toJson(card.images),
    card.audioPath,
    card.visionAnalyzed == null ? null : card.visionAnalyzed ? 1 : 0,
    toJson(card.tags),
    card.confidence,
    card.ask,
    card.pathSuggestion,
    card.pathMatched == null ? null : card.pathMatched ? 1 : 0,
    card.source,
    card.retryCount,
    card.nextRetryAt,
    card.lastError,
    card.createdAt,
    card.updatedAt,
  );
}

export function getCard(db: SqliteDriver, id: string): MemoryCard | undefined {
  const row = db.prepare('SELECT * FROM cards WHERE id = ?').get(id) as
    | Record<string, unknown>
    | undefined;
  return row ? rowToCard(row) : undefined;
}

export interface ParsedCardFields {
  structureType: StructureType;
  categoryId: string | null;
  entity: string;
  pathIds: string[] | null;
  pathNames: string | null;
  steps: StepItem[] | null;
  desc: string;
  tags: string[];
  confidence: number | null;
  aliases: string[];
  ask?: string | null;
  pathSuggestion?: string | null;
  pathMatched?: boolean | null;
}

export function applyParseResult(
  db: SqliteDriver,
  id: string,
  f: ParsedCardFields,
  needsConfirm: boolean,
  now: Date,
  idGen: () => string = makeId,
): void {
  db.transaction(() => {
    db.prepare(
      `UPDATE cards SET status = 'active', needs_confirm = ?, structure_type = ?, category_id = ?,
       entity = ?, path_ids = ?, path_names = ?, steps = ?, desc_text = ?, tags = ?, confidence = ?,
       ask = ?, path_suggestion = ?, path_matched = ?, updated_at = ? WHERE id = ?`,
    ).run(
      needsConfirm ? 1 : 0,
      f.structureType,
      f.categoryId,
      f.entity,
      toJson(f.pathIds),
      f.pathNames,
      toJson(f.steps),
      f.desc,
      toJson(f.tags),
      f.confidence,
      f.ask ?? null,
      f.pathSuggestion ?? null,
      f.pathMatched == null ? null : f.pathMatched ? 1 : 0,
      now.toISOString(),
      id,
    );
    for (const a of f.aliases) {
      const name = a.trim();
      if (!name) continue;
      db.prepare(
        "INSERT OR IGNORE INTO aliases (id, kind, name, card_id) VALUES (?, 'entity', ?, ?)",
      ).run(idGen(), name, id);
    }
  });
}

export function markNeedsOrganize(db: SqliteDriver, id: string, now: Date): void {
  db.prepare(
    "UPDATE cards SET status = 'active', needs_organize = 1, updated_at = ? WHERE id = ?",
  ).run(now.toISOString(), id);
}

/**
 * 记一次可重试的失败：retry_count 自增，并按退避序列算出 next_retry_at。
 * 是否还能被队列自动捞起由 listQueueCards 的 retry_count < MAX_AUTO_RETRY 决定——
 * 因此第 5 次失败仍会排期，但排完就只剩手动重试 / 批量补转写。
 */
export function markRetry(db: SqliteDriver, id: string, error: string, now: Date): void {
  const nextCount = (getCard(db, id)?.retryCount ?? 0) + 1;
  const nextAt = new Date(now.getTime() + computeBackoffMs(nextCount)).toISOString();
  db.prepare(
    'UPDATE cards SET retry_count = ?, last_error = ?, next_retry_at = ?, updated_at = ? WHERE id = ?',
  ).run(nextCount, error, nextAt, now.toISOString(), id);
}

export function listCategories(db: SqliteDriver): Category[] {
  const rows = db.prepare('SELECT * FROM categories ORDER BY sort').all() as Record<
    string,
    unknown
  >[];
  return rows.map((r) => ({
    id: String(r.id),
    name: String(r.name),
    emoji: (r.emoji as string | null) ?? null,
    description: (r.description as string | null) ?? null,
    structureType: r.structure_type as StructureType,
    sort: Number(r.sort),
    isPreset: r.is_preset === 1,
  }));
}

export function listLocations(db: SqliteDriver): LocationNode[] {
  const rows = db.prepare('SELECT * FROM locations ORDER BY sort').all() as Record<
    string,
    unknown
  >[];
  return rows.map((r) => ({
    id: String(r.id),
    parentId: (r.parent_id as string | null) ?? null,
    name: String(r.name),
    sort: Number(r.sort),
  }));
}

export function upsertLocation(db: SqliteDriver, node: LocationNode): void {
  db.prepare(
    'INSERT OR IGNORE INTO locations (id, parent_id, name, sort) VALUES (?, ?, ?, ?)',
  ).run(node.id, node.parentId, node.name, node.sort);
}

/**
 * 判定码点是否属于「汉字」范畴。
 * 刻意不用 /\p{Script=Han}/u —— Hermes 对 Unicode property escape 的支持历来不稳，
 * 而这条路径在每次 P1 入库时都会走到，一旦抛错整条录入链路就断了。
 */
function isHanCodePoint(cp: number): boolean {
  return (
    (cp >= 0x3400 && cp <= 0x4dbf) || // 扩展 A
    (cp >= 0x4e00 && cp <= 0x9fff) || // 基本区
    (cp >= 0xf900 && cp <= 0xfaff) || // 兼容表意文字
    (cp >= 0x20000 && cp <= 0x2ebef) // 扩展 B~F
  );
}

function isAsciiAlphanumeric(cp: number): boolean {
  return (cp >= 0x30 && cp <= 0x39) || (cp >= 0x41 && cp <= 0x5a) || (cp >= 0x61 && cp <= 0x7a);
}

function normalizeCategoryName(s: string): string {
  let out = '';
  for (const ch of s) {
    const cp = ch.codePointAt(0) ?? 0;
    if (isHanCodePoint(cp) || isAsciiAlphanumeric(cp)) out += ch;
  }
  return out.toLowerCase();
}

/** 分类名匹配（容忍模型回显带 emoji / 空白 / 标点的变体） */
export function resolveCategoryId(db: SqliteDriver, name: string): string | null {
  const rows = listCategories(db);
  const exact = rows.find((c) => c.name === name);
  if (exact) return exact.id;
  const target = normalizeCategoryName(name);
  if (!target) return null;
  const loose = rows.find((c) => {
    const n = normalizeCategoryName(c.name);
    return n.length > 0 && (n === target || target.includes(n) || n.includes(target));
  });
  return loose?.id ?? null;
}

/** 按位置名逐级匹配已有位置树；任一级失配返回 null（由用户确认后写入） */
export function resolvePath(
  db: SqliteDriver,
  names: string[],
): { ids: string[]; namesStr: string } | null {
  const ids: string[] = [];
  let parent: string | null = null;
  for (const name of names) {
    const row = db
      .prepare('SELECT id FROM locations WHERE name = ? AND parent_id IS ?')
      .get(name, parent) as { id: string } | undefined;
    if (!row) return null;
    ids.push(row.id);
    parent = row.id;
  }
  return { ids, namesStr: names.join('/') };
}

/** 别名命中后把实体规范名补进检索词 */
export function expandTermsByAliases(db: SqliteDriver, terms: string[]): string[] {
  const extra: string[] = [];
  for (const t of terms) {
    const row = db
      .prepare(
        'SELECT c.entity FROM aliases a JOIN cards c ON c.id = a.card_id WHERE a.name = ?',
      )
      .get(t) as { entity: string | null } | undefined;
    if (row?.entity && !terms.includes(row.entity) && !extra.includes(row.entity)) {
      extra.push(row.entity);
    }
  }
  return extra;
}

/**
 * 混合检索执行器：≥3 字词走 FTS trigram（bm25 权重 transcript 1.0 / desc 3.0 / entity 4.0 / tags 2.0），
 * <3 字词走 LIKE 降级。any 模式两路并集（FTS 优先）；all 模式 FTS 命中且 AND 所有短词。
 * 恒定条件：status='active'。结果按 score 升序（bm25 越小越相关；LIKE 命中固定低优先）、created_at 降序。
 */
export function executeSearch(db: SqliteDriver, s: BuiltSearch): MemoryCard[] {
  const filters: string[] = ["c.status = 'active'"];
  const filterParams: unknown[] = [];
  if (s.categoryId) {
    filters.push('c.category_id = ?');
    filterParams.push(s.categoryId);
  }
  if (s.sinceIso) {
    filters.push('c.created_at >= ?');
    filterParams.push(s.sinceIso);
  }
  if (s.pathPrefixLike) {
    filters.push(`c.path_names LIKE ? ESCAPE '\\'`);
    filterParams.push(s.pathPrefixLike);
  }
  const filterSql = filters.length > 0 ? ' AND ' + filters.join(' AND ') : '';

  interface Hit {
    card: MemoryCard;
    score: number;
    createdAt: string;
  }
  const hits = new Map<string, Hit>();
  const addRows = (rows: Record<string, unknown>[], fallbackScore: number | null) => {
    for (const r of rows) {
      const card = rowToCard(r);
      const score = fallbackScore == null ? Number(r.score) : fallbackScore;
      const prev = hits.get(card.id);
      if (!prev || prev.score > score) hits.set(card.id, { card, score, createdAt: card.createdAt });
    }
  };

  const likeTermConds: string[] = [];
  const likeTermParams: unknown[] = [];
  for (const t of s.likeTerms) {
    const p = `%${escapeLike(t)}%`;
    likeTermParams.push(p, p, p, p);
    likeTermConds.push(
      `(c.desc_text LIKE ? ESCAPE '\\' OR c.transcript LIKE ? ESCAPE '\\' OR c.entity LIKE ? ESCAPE '\\' OR c.tags LIKE ? ESCAPE '\\')`,
    );
  }

  if (s.ftsExpr) {
    let sql =
      'SELECT c.*, bm25(cards_fts, 1.0, 3.0, 4.0, 2.0) AS score FROM cards_fts JOIN cards c ON c.rowid = cards_fts.rowid WHERE cards_fts MATCH ?' +
      filterSql;
    const params: unknown[] = [s.ftsExpr, ...filterParams];
    if (s.matchMode === 'all' && likeTermConds.length > 0) {
      sql += ' AND ' + likeTermConds.join(' AND ');
      params.push(...likeTermParams);
    }
    addRows(db.prepare(sql).all(...params) as Record<string, unknown>[], null);
    if (s.matchMode === 'any' && likeTermConds.length > 0) {
      const sql2 = `SELECT c.* FROM cards c WHERE (${likeTermConds.join(' OR ')})${filterSql}`;
      addRows(db.prepare(sql2).all(...likeTermParams, ...filterParams) as Record<string, unknown>[], 1e9);
    }
  } else if (likeTermConds.length > 0) {
    const joiner = s.matchMode === 'all' ? ' AND ' : ' OR ';
    const sql = `SELECT c.* FROM cards c WHERE (${likeTermConds.join(joiner)})${filterSql}`;
    addRows(
      db.prepare(sql).all(...likeTermParams, ...filterParams) as Record<string, unknown>[],
      1e9,
    );
  }

  return [...hits.values()]
    .sort((a, b) => a.score - b.score || (a.createdAt < b.createdAt ? 1 : -1))
    .slice(0, s.limit)
    .map((h) => h.card);
}
