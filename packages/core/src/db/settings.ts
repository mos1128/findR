import type { SqliteDriver } from './driver';

/**
 * settings 表只存非机密项（JSON 值）；API Key 一律走 SecureStore，
 * 导出备份也永不包含（技术设计四「Key 与配置分离」）。
 */
export function getSetting<T>(db: SqliteDriver, key: string): T | null {
  const row = db.prepare('SELECT value FROM settings WHERE key = ?').get(key) as
    | { value: string }
    | undefined;
  if (!row) return null;
  try {
    return JSON.parse(row.value) as T;
  } catch {
    return null;
  }
}

export function setSetting(db: SqliteDriver, key: string, value: unknown): void {
  db.prepare(
    'INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
  ).run(key, JSON.stringify(value));
}

export function deleteSetting(db: SqliteDriver, key: string): void {
  db.prepare('DELETE FROM settings WHERE key = ?').run(key);
}

export function listSettings(db: SqliteDriver): Record<string, unknown> {
  const rows = db.prepare('SELECT key, value FROM settings').all() as {
    key: string;
    value: string;
  }[];
  const out: Record<string, unknown> = {};
  for (const r of rows) {
    try {
      out[r.key] = JSON.parse(r.value);
    } catch {
      // 坏值不阻塞其余设置读取
    }
  }
  return out;
}
