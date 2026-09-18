import type { SqliteDriver } from './driver';
import { SCHEMA_V1_STATEMENTS, SEED_STATEMENTS, V2_STATEMENTS } from './schema';

/**
 * 一个迁移版本 = 一组「一条 DDL 一个元素」的语句，按数组顺序执行。
 *
 * `withoutForeignKeys` 是给「重建表」用的：只要脚本里出现 DROP TABLE + RENAME 来改表结构，
 * 而该表被别的表外键引用（cards.category_id → categories），开着外键的 DROP 会触发隐式
 * 删除并被约束拒绝。SQLite 官方的改表流程也要求先关外键、改完再开回来。
 */
interface Migration {
  /** 只用于报错定位 */
  name: string;
  statements: readonly string[];
  withoutForeignKeys?: boolean;
}

/**
 * 迁移链。**只追加，不修改已发布的历史条目**（见 schema.ts 顶部的迁移纪律）。
 * 数组长度即 SCHEMA_VERSION —— 备份包导入时用它挡住「包里比我新」的情况。
 */
const MIGRATIONS: readonly Migration[] = [
  { name: 'v1-initial', statements: SCHEMA_V1_STATEMENTS },
  { name: 'v2-drop-structure-and-schedule-fields', statements: V2_STATEMENTS, withoutForeignKeys: true },
];

export const SCHEMA_VERSION = MIGRATIONS.length;

/** 读出库存的 schema_version（未建库返回 0）。备份导出用它给 manifest 打标 */
export function currentSchemaVersion(db: SqliteDriver): number {
  const table = db
    .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'schema_meta'")
    .get();
  if (!table) return 0;
  const row = db
    .prepare("SELECT value FROM schema_meta WHERE key = 'schema_version'")
    .get() as { value: string } | undefined;
  return row ? Number(row.value) : 0;
}

function foreignKeysEnabled(db: SqliteDriver): boolean {
  const row = db.prepare('PRAGMA foreign_keys').get() as { foreign_keys?: number } | undefined;
  return row?.foreign_keys === 1;
}

/** 单个版本：整体一个事务（SQLite 的 DDL 是事务性的），需要时临时关外键 */
function runMigration(db: SqliteDriver, m: Migration): void {
  const restoreFk = !!m.withoutForeignKeys && foreignKeysEnabled(db);
  // PRAGMA 在事务内是空操作，必须在 BEGIN 之前执行
  if (m.withoutForeignKeys) db.exec('PRAGMA foreign_keys = OFF');
  try {
    db.transaction(() => {
      for (const statement of m.statements) db.exec(statement);
    });
    if (m.withoutForeignKeys) {
      // 重建期间外键是关的，这里显式查一遍，别把引用错误拖到运行期才炸
      const bad = db.prepare('PRAGMA foreign_key_check').all();
      if (bad.length > 0) throw new Error(`迁移后存在外键违规（${m.name}）：${bad.length} 行`);
    }
  } finally {
    if (restoreFk) db.exec('PRAGMA foreign_keys = ON');
  }
}

export function migrate(db: SqliteDriver): void {
  db.exec('CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
  const current = currentSchemaVersion(db);
  for (let i = current; i < MIGRATIONS.length; i++) {
    runMigration(db, MIGRATIONS[i]);
  }
  db.prepare(
    "INSERT INTO schema_meta (key, value) VALUES ('schema_version', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
  ).run(String(MIGRATIONS.length));
  // 只在首次建库时播种：分类是完整 CRUD 的对象，每次开库重跑会让删掉的预设分类复活
  if (current === 0) {
    for (const statement of SEED_STATEMENTS) db.exec(statement);
  }
}
