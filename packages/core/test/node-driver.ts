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
  // 与设备端驱动保持同一套 PRAGMA（见技术设计三）：漏掉 foreign_keys 会出现
  // 「本地测试全绿、真机 insert 被外键拒」的不对称
  db.exec('PRAGMA foreign_keys = ON');
  return {
    exec: (sql: string) => db.exec(sql),
    prepare: (sql: string) => db.prepare(sql) as unknown as SqliteStatement,
    transaction: <T>(fn: () => T): T => db.transaction(fn)(),
  };
}
