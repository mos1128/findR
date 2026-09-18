import type { SqliteDriver } from '../db/driver';
import { listSettings } from '../db/settings';
import { rowToCard, upsertCard, resolveCategoryId } from '../db/repository';
import { SETTINGS_KEYS } from '../settings';
import type { MemoryCard } from '../types';
import type {
  BackupAlias,
  BackupCategory,
  BackupLocation,
  BackupManifest,
  ImportReport,
} from './types';
import { FORMAT_VERSION } from './format';

/**
 * manifest 的生成与合并。
 *
 * 导出侧的安全原则（技术设计七「永不包含 API Key 与生物锁设置」）：
 * settings 走**白名单**——只有 SETTINGS_KEYS 里列出的键可能进包，再叠一层按键名剥除，
 * 而不是「过滤掉看起来像密钥的」。方向反过来，才能在将来有人往 settings 里塞新东西时
 * 默认是「不导出」而不是「导出」。API Key 本身只在 SecureStore，压根不在 settings 表里。
 */
const SECRET_KEY_PATTERN = /(api[_-]?key|secret|token|password|passphrase|credential|biometric|生物锁|指纹|face)/i;

function stripSecrets(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(stripSecrets);
  if (value && typeof value === 'object') {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      if (SECRET_KEY_PATTERN.test(k)) continue;
      out[k] = stripSecrets(v);
    }
    return out;
  }
  return value;
}

/** 供导出使用的非机密设置：白名单键 + 深度剥除 */
export function publicSettings(db: SqliteDriver): Record<string, unknown> {
  const all = listSettings(db);
  const out: Record<string, unknown> = {};
  for (const key of Object.values(SETTINGS_KEYS)) {
    if (key in all) out[key] = stripSecrets(all[key]);
  }
  return out;
}

export function readAllCards(db: SqliteDriver): MemoryCard[] {
  // 备份范围是「全部表」：归档卡也要进包，否则换机后归档过的记忆会凭空消失
  return (db.prepare('SELECT * FROM cards').all() as Record<string, unknown>[]).map(rowToCard);
}

function readCategories(db: SqliteDriver): BackupCategory[] {
  const rows = db.prepare('SELECT * FROM categories ORDER BY sort').all() as Record<
    string,
    unknown
  >[];
  return rows.map((r) => ({
    id: String(r.id),
    name: String(r.name),
    emoji: (r.emoji as string | null) ?? null,
    description: (r.description as string | null) ?? null,
    structureType: r.structure_type as BackupCategory['structureType'],
    sort: Number(r.sort),
    isPreset: r.is_preset === 1,
  }));
}

function readLocations(db: SqliteDriver): BackupLocation[] {
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

function readAliases(db: SqliteDriver): BackupAlias[] {
  const rows = db.prepare('SELECT * FROM aliases').all() as Record<string, unknown>[];
  return rows.map((r) => ({
    id: String(r.id),
    kind: r.kind as BackupAlias['kind'],
    name: String(r.name),
    cardId: (r.card_id as string | null) ?? null,
    locationId: (r.location_id as string | null) ?? null,
  }));
}

/** 卡片引用到的媒体相对路径全集（去重）。DB 里可能引用已回收的文件，读取侧按缺失处理 */
export function collectMediaPaths(cards: readonly MemoryCard[]): string[] {
  const set = new Set<string>();
  for (const c of cards) {
    for (const p of c.images ?? []) if (p) set.add(p);
    if (c.audioPath) set.add(c.audioPath);
  }
  return [...set];
}

export interface BuiltManifest {
  manifest: BackupManifest;
  mediaPaths: string[];
}

/** 组装 manifest（media 索引此时还是空的，由 pack.ts 实际写完文件后回填） */
export function buildManifest(
  db: SqliteDriver,
  schemaVersion: number,
  now: Date,
  appVersion?: string,
): BuiltManifest {
  const cards = readAllCards(db);
  const manifest: BackupManifest = {
    format: 'findrpack',
    formatVersion: FORMAT_VERSION,
    schemaVersion,
    exportedAt: now.toISOString(),
    appVersion,
    cards,
    categories: readCategories(db),
    locations: readLocations(db),
    aliases: readAliases(db),
    settings: publicSettings(db),
    media: [],
  };
  return { manifest, mediaPaths: collectMediaPaths(cards) };
}

// ─────────────────────────────────────────────────────────────
// 导入合并
// ─────────────────────────────────────────────────────────────

function emptyReport(): ImportReport {
  return {
    cardsInserted: 0,
    cardsUpdated: 0,
    cardsKeptLocal: 0,
    categoriesInserted: 0,
    categoriesKeptLocal: 0,
    locationsInserted: 0,
    locationsKeptLocal: 0,
    aliasesInserted: 0,
    settingsWritten: 0,
    settingsKeptLocal: 0,
    mediaWritten: 0,
    mediaOverwritten: 0,
    remappedCategoryRefs: 0,
    remappedLocationRefs: 0,
    droppedRefs: 0,
    conflicts: [],
  };
}

/**
 * 合并策略（技术设计七）：按 id 幂等 upsert、updated_at 新者胜、**不删除本地任何数据**、
 * 分类/位置同名冲突保留本地并把外来 id 重映射到本地 id。
 *
 * 只碰 DB；媒体文件由 pack.ts 在调用本函数之前写入磁盘。
 */
export function mergeManifest(
  db: SqliteDriver,
  manifest: BackupManifest,
): ImportReport {
  const report = emptyReport();

  db.transaction(() => {
    const categoryIdMap = mergeCategories(db, manifest.categories, report);
    const locationIdMap = mergeLocations(db, manifest.locations, report);
    mergeCards(db, manifest, categoryIdMap, locationIdMap, report);
    mergeAliases(db, manifest.aliases, report);
    mergeSettings(db, manifest.settings, report);
  });

  return report;
}

function mergeCategories(
  db: SqliteDriver,
  incoming: readonly BackupCategory[],
  report: ImportReport,
): Map<string, string> {
  const map = new Map<string, string>();
  for (const c of incoming) {
    const byId = db.prepare('SELECT id FROM categories WHERE id = ?').get(c.id) as
      | { id: string }
      | undefined;
    if (byId) {
      map.set(c.id, c.id);
      report.categoriesKeptLocal++;
      continue;
    }
    // 同名不同 id：保留本地那条，把外来 id 映射过去。
    // 刻意不往 aliases 写这条（技术设计七说「写进 aliases」，但 aliases.kind 只有
    // entity/location 两种，且分类名一致时 resolveCategoryId 本来就按名字命中本地分类，
    // 补一条空挂在 aliases 里只会留垃圾行）。冲突记进报告，由 UI 决定要不要提示用户。
    const byName = db.prepare('SELECT id FROM categories WHERE name = ?').get(c.name) as
      | { id: string }
      | undefined;
    if (byName) {
      map.set(c.id, byName.id);
      report.categoriesKeptLocal++;
      report.conflicts.push({
        kind: 'category',
        importedId: c.id,
        localId: byName.id,
        name: c.name,
      });
      continue;
    }
    db.prepare(
      `INSERT INTO categories (id, name, emoji, description, structure_type, sort, is_preset)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    ).run(c.id, c.name, c.emoji, c.description, c.structureType, c.sort, c.isPreset ? 1 : 0);
    map.set(c.id, c.id);
    report.categoriesInserted++;
  }
  return map;
}

/** 父节点必须先于子节点落库，否则外键直接拒。按「父链深度」排序而不是按 manifest 顺序 */
function orderByDepth(locations: readonly BackupLocation[]): BackupLocation[] {
  const byId = new Map(locations.map((l) => [l.id, l]));
  const depth = (l: BackupLocation): number => {
    let d = 0;
    let cur = l.parentId;
    const seen = new Set<string>([l.id]);
    while (cur && byId.has(cur) && !seen.has(cur)) {
      seen.add(cur);
      d++;
      cur = byId.get(cur)?.parentId ?? null;
    }
    return d;
  };
  return [...locations].sort((a, b) => depth(a) - depth(b));
}

function mergeLocations(
  db: SqliteDriver,
  incoming: readonly BackupLocation[],
  report: ImportReport,
): Map<string, string> {
  const map = new Map<string, string>();
  for (const l of orderByDepth(incoming)) {
    const byId = db.prepare('SELECT id FROM locations WHERE id = ?').get(l.id) as
      | { id: string }
      | undefined;
    if (byId) {
      map.set(l.id, l.id);
      report.locationsKeptLocal++;
      continue;
    }

    // 父节点也要跟着重映射（父可能因同名冲突被换成了本地 id）
    let parentId = l.parentId ? (map.get(l.parentId) ?? null) : null;
    if (l.parentId && !parentId) {
      const exists = db.prepare('SELECT id FROM locations WHERE id = ?').get(l.parentId);
      parentId = exists ? l.parentId : null;
      if (!parentId) report.droppedRefs++;
    }

    const byName = db
      .prepare('SELECT id FROM locations WHERE name = ? AND parent_id IS ?')
      .get(l.name, parentId) as { id: string } | undefined;
    if (byName) {
      map.set(l.id, byName.id);
      report.locationsKeptLocal++;
      report.conflicts.push({
        kind: 'location',
        importedId: l.id,
        localId: byName.id,
        name: l.name,
      });
      continue;
    }

    db.prepare('INSERT INTO locations (id, parent_id, name, sort) VALUES (?, ?, ?, ?)').run(
      l.id,
      parentId,
      l.name,
      l.sort,
    );
    map.set(l.id, l.id);
    report.locationsInserted++;
  }
  return map;
}

function locationNames(db: SqliteDriver, ids: string[]): string | null {
  const names: string[] = [];
  for (const id of ids) {
    const row = db.prepare('SELECT name FROM locations WHERE id = ?').get(id) as
      | { name: string }
      | undefined;
    if (!row) return null;
    names.push(row.name);
  }
  return names.join('/');
}

function mergeCards(
  db: SqliteDriver,
  manifest: BackupManifest,
  categoryIdMap: Map<string, string>,
  locationIdMap: Map<string, string>,
  report: ImportReport,
): void {
  for (const card of manifest.cards) {
    const local = db.prepare('SELECT id, updated_at FROM cards WHERE id = ?').get(card.id) as
      | { id: string; updated_at: string }
      | undefined;

    if (local && !(card.updatedAt > local.updated_at)) {
      // updated_at 相同或本地更新 → 本地胜。同值也判本地胜，避免同一份包导入两次来回抖动
      report.cardsKeptLocal++;
      continue;
    }

    const next: MemoryCard = { ...card };

    // 外键重映射：导入的分类/位置 id 在本地可能是另一个 id（同名冲突），也可能压根没来
    if (next.categoryId) {
      const mapped = categoryIdMap.get(next.categoryId) ?? next.categoryId;
      const exists = db.prepare('SELECT id FROM categories WHERE id = ?').get(mapped);
      if (exists) {
        if (mapped !== next.categoryId) report.remappedCategoryRefs++;
        next.categoryId = mapped;
      } else {
        const src = manifest.categories.find((c) => c.id === next.categoryId);
        const byName = src ? resolveCategoryId(db, src.name) : null;
        next.categoryId = byName;
        if (byName) report.remappedCategoryRefs++;
        else report.droppedRefs++;
      }
    }

    if (next.pathIds && next.pathIds.length > 0) {
      const mapped: string[] = [];
      let allMapped = true;
      for (const id of next.pathIds) {
        const to = locationIdMap.get(id) ?? id;
        const exists = db.prepare('SELECT id FROM locations WHERE id = ?').get(to);
        if (exists) {
          if (to !== id) allMapped = false;
          mapped.push(to);
        } else {
          allMapped = false;
        }
      }
      if (!allMapped) {
        report.remappedLocationRefs += mapped.length;
        report.droppedRefs += next.pathIds.length - mapped.length;
        next.pathIds = mapped.length > 0 ? mapped : null;
        // path_names 是 path_ids 的反规范化副本，id 变了就必须跟着重算，否则检索会拿旧名字匹配
        next.pathNames = mapped.length > 0 ? locationNames(db, mapped) : null;
      }
    }

    upsertCard(db, next);
    if (local) report.cardsUpdated++;
    else report.cardsInserted++;
  }
  // manifest 里没有的卡片保持原样——「不删除本地任何数据」是硬约束，这里刻意什么都不做
}

function mergeAliases(
  db: SqliteDriver,
  incoming: readonly BackupAlias[],
  report: ImportReport,
): void {
  for (const a of incoming) {
    // (kind, name) 唯一约束：导入包里与本地重名的别名会被 IGNORE 掉，这符合「保留本地」
    const r = db
      .prepare(
        'INSERT OR IGNORE INTO aliases (id, kind, name, card_id, location_id) VALUES (?, ?, ?, ?, ?)',
      )
      .run(a.id, a.kind, a.name, a.cardId, a.locationId);
    if (r.changes > 0) report.aliasesInserted++;
  }
}

function mergeSettings(
  db: SqliteDriver,
  incoming: Record<string, unknown>,
  report: ImportReport,
): void {
  for (const [key, value] of Object.entries(incoming)) {
    // 只补本地没有的键：同一台机器上重复导入不该把用户改过的设置冲掉
    const exists = db.prepare('SELECT key FROM settings WHERE key = ?').get(key);
    if (exists) {
      report.settingsKeptLocal++;
      continue;
    }
    db.prepare('INSERT INTO settings (key, value) VALUES (?, ?)').run(key, JSON.stringify(value));
    report.settingsWritten++;
  }
}
