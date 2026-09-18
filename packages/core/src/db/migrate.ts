import type { SqliteDriver } from './driver';
import { SCHEMA_SQL, SEED_SQL } from './schema';

const MIGRATIONS: readonly string[] = [SCHEMA_SQL];

export function migrate(db: SqliteDriver): void {
  db.exec('CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
  const row = db
    .prepare("SELECT value FROM schema_meta WHERE key = 'schema_version'")
    .get() as { value: string } | undefined;
  const current = row ? Number(row.value) : 0;
  for (let i = current; i < MIGRATIONS.length; i++) db.exec(MIGRATIONS[i]);
  db.prepare(
    "INSERT INTO schema_meta (key, value) VALUES ('schema_version', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
  ).run(String(MIGRATIONS.length));
  db.exec(SEED_SQL);
}
