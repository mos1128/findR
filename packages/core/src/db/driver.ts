export interface SqliteStatement {
  run(...params: unknown[]): { changes: number; lastInsertRowid: number | bigint };
  get(...params: unknown[]): unknown;
  all(...params: unknown[]): unknown[];
}

/** 驱动注入接口：node 测试用 better-sqlite3，App 内用 op-sqlite，core 不感知平台 */
export interface SqliteDriver {
  exec(sql: string): void;
  prepare(sql: string): SqliteStatement;
  transaction<T>(fn: () => T): T;
}
