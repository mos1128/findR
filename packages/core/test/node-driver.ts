import type { SqliteDriver, SqliteStatement } from '../src/db/driver';

/** better-sqlite3 实例的最小结构面（避开其命名空间类型声明），node 测试用；App 内由 op-sqlite 实现同一接口 */
export interface BetterSqliteDatabase {
  exec(sql: string): void;
  prepare(sql: string): {
    run(...params: unknown[]): unknown;
    get(...params: unknown[]): unknown;
    all(...params: unknown[]): unknown[];
  };
  transaction<T>(fn: () => T): () => T;
}

export function nodeDriver(db: BetterSqliteDatabase): SqliteDriver {
  return {
    exec: (sql: string) => db.exec(sql),
    prepare: (sql: string) => db.prepare(sql) as unknown as SqliteStatement,
    transaction: <T>(fn: () => T): T => db.transaction(fn)(),
  };
}
