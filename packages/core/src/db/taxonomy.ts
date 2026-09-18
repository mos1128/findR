import type { Category, LocationNode } from '../types';
import type { SqliteDriver } from './driver';
import { parseJsonArray } from './json';
import { listLocations } from './repository';

// ─────────────────────────────────────────────────────────────
// 分类
// ─────────────────────────────────────────────────────────────

/**
 * 按 id 新增或更新分类。name 上有 UNIQUE 约束，重名会直接抛错——
 * 有意如此：静默改名会让用户以为保存成功，而 P1 的路由是按名字匹配的。
 */
export function upsertCategory(db: SqliteDriver, category: Category): void {
  db.prepare(
    `INSERT INTO categories (id, name, emoji, description, sort, is_preset)
     VALUES (?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       name = excluded.name,
       emoji = excluded.emoji,
       description = excluded.description,
       sort = excluded.sort`,
  ).run(
    category.id,
    category.name,
    category.emoji,
    category.description,
    category.sort,
    category.isPreset ? 1 : 0,
  );
}

/** 删除分类：先把引用它的卡片置空，避免卡片指向不存在的分类 */
export function deleteCategory(db: SqliteDriver, id: string, now: Date): number {
  return db.transaction(() => {
    const affected = db
      .prepare('UPDATE cards SET category_id = NULL, updated_at = ? WHERE category_id = ?')
      .run(now.toISOString(), id).changes;
    db.prepare('DELETE FROM categories WHERE id = ?').run(id);
    return affected;
  });
}

/** 批量重排：按传入顺序写 sort */
export function reorderCategories(db: SqliteDriver, ids: string[]): void {
  db.transaction(() => {
    ids.forEach((id, index) => {
      db.prepare('UPDATE categories SET sort = ? WHERE id = ?').run(index, id);
    });
  });
}

// ─────────────────────────────────────────────────────────────
// 位置树
// ─────────────────────────────────────────────────────────────

export function upsertLocationNode(db: SqliteDriver, node: LocationNode): void {
  db.prepare(
    `INSERT INTO locations (id, parent_id, name, sort) VALUES (?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET parent_id = excluded.parent_id, name = excluded.name, sort = excluded.sort`,
  ).run(node.id, node.parentId, node.name, node.sort);
}

export function renameLocation(db: SqliteDriver, id: string, name: string): void {
  db.prepare('UPDATE locations SET name = ? WHERE id = ?').run(name, id);
}

export function listLocationChildren(db: SqliteDriver, parentId: string | null): LocationNode[] {
  const rows = db
    .prepare('SELECT * FROM locations WHERE parent_id IS ? ORDER BY sort')
    .all(parentId) as Record<string, unknown>[];
  return rows.map((r) => ({
    id: String(r.id),
    parentId: (r.parent_id as string | null) ?? null,
    name: String(r.name),
    sort: Number(r.sort),
  }));
}

export type DeleteLocationResult =
  | { ok: true }
  | { ok: false; reason: 'has_children' | 'referenced_by_cards'; count: number };

/**
 * 删除位置节点。有子节点或被任何卡片引用时拒绝——
 * M1 不做 reparent / 合并，静默删掉会让卡片的 path_ids 指向空洞。
 */
export function deleteLocation(db: SqliteDriver, id: string): DeleteLocationResult {
  const children = db
    .prepare('SELECT COUNT(*) AS n FROM locations WHERE parent_id = ?')
    .get(id) as { n?: number } | undefined;
  if (Number(children?.n ?? 0) > 0) {
    return { ok: false, reason: 'has_children', count: Number(children?.n ?? 0) };
  }
  const used = db
    .prepare(`SELECT COUNT(*) AS n FROM cards WHERE path_ids LIKE ?`)
    .get(`%"${id}"%`) as { n?: number } | undefined;
  if (Number(used?.n ?? 0) > 0) {
    return { ok: false, reason: 'referenced_by_cards', count: Number(used?.n ?? 0) };
  }
  db.prepare('DELETE FROM locations WHERE id = ?').run(id);
  return { ok: true };
}

/**
 * 位置改名后重算卡片的 path_names（卡片的权威位置是 path_ids，这里只是冗余串）。
 * 返回实际改动的卡片数。节点已被删除的卡片跳过，保留原值而不是写出空洞。
 */
export function refreshPathNames(db: SqliteDriver, now: Date): number {
  const byId = new Map(listLocations(db).map((l) => [l.id, l]));
  const rows = db
    .prepare('SELECT id, path_names, path_ids FROM cards WHERE path_ids IS NOT NULL')
    .all() as { id: string; path_names: string | null; path_ids: string | null }[];

  let changed = 0;
  db.transaction(() => {
    for (const row of rows) {
      const ids = parseJsonArray<string>(row.path_ids);
      if (!ids || ids.length === 0) continue;
      const names = ids.map((i) => byId.get(i)?.name);
      if (names.some((n) => n == null)) continue;
      const namesStr = names.join('/');
      if (namesStr === row.path_names) continue;
      db.prepare('UPDATE cards SET path_names = ?, updated_at = ? WHERE id = ?').run(
        namesStr,
        now.toISOString(),
        row.id,
      );
      changed++;
    }
  });
  return changed;
}

// ─────────────────────────────────────────────────────────────
// ASR 热词
// ─────────────────────────────────────────────────────────────

/** 位置树深度（根为 1） */
function depthOf(byId: Map<string, LocationNode>, node: LocationNode): number {
  let d = 1;
  let cur: LocationNode | undefined = node;
  while (cur?.parentId) {
    cur = byId.get(cur.parentId);
    d++;
  }
  return d;
}

/**
 * 模式 2 专用 ASR 的热词：房间名（只取一二级）+ 高频实体名。
 * 需求 3.2 明确热词用来提升「房间名、常用物品名」的转写准确率。
 */
export function collectHotwords(db: SqliteDriver, entityLimit = 20): string[] {
  const locations = listLocations(db);
  const byId = new Map(locations.map((l) => [l.id, l]));
  const words: string[] = [];
  for (const l of locations) {
    if (depthOf(byId, l) <= 2) words.push(l.name);
  }
  const rows = db
    .prepare(
      `SELECT entity FROM cards
       WHERE entity IS NOT NULL AND entity <> ''
       GROUP BY entity
       ORDER BY COUNT(*) DESC, MAX(created_at) DESC
       LIMIT ?`,
    )
    .all(entityLimit) as { entity: string }[];
  for (const r of rows) {
    if (!words.includes(r.entity)) words.push(r.entity);
  }
  return words;
}
