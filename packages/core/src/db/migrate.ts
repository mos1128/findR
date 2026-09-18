import type { SqliteDriver } from './driver';
import { SCHEMA_STATEMENTS, SEED_STATEMENTS } from './schema';

/** 迁移 = 顺序脚本数组，开库时从 schema_version 补跑到末尾；每版是一组「一条 DDL 一个元素」的语句 */
const MIGRATIONS: readonly (readonly string[])[] = [SCHEMA_STATEMENTS];

export function migrate(db: SqliteDriver): void {
  db.exec('CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
  const row = db
    .prepare("SELECT value FROM schema_meta WHERE key = 'schema_version'")
    .get() as { value: string } | undefined;
  const current = row ? Number(row.value) : 0;
  for (let i = current; i < MIGRATIONS.length; i++) {
    for (const statement of MIGRATIONS[i]) db.exec(statement);
  }
  db.prepare(
    "INSERT INTO schema_meta (key, value) VALUES ('schema_version', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
  ).run(String(MIGRATIONS.length));
  // 只在首次建库时播种：分类是完整 CRUD 的对象，每次开库重跑会让删掉的预设分类复活
  if (current === 0) {
    for (const statement of SEED_STATEMENTS) db.exec(statement);
  }
}
