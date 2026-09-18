import { open } from '@op-engineering/op-sqlite';
import type { SqliteDriver, SqliteStatement } from '@findr/core';

type OPSQLiteScalar = string | number | boolean | null | ArrayBuffer | ArrayBufferView;

interface OPSQLiteResult {
  insertId?: number;
  rowsAffected?: number;
  rows?: Array<Record<string, OPSQLiteScalar>>;
}

interface OPSQLiteDB {
  executeSync: (query: string, params?: OPSQLiteScalar[]) => OPSQLiteResult;
  close: () => void;
  getDbPath: () => string;
}

export const DB_NAME = 'findr.sqlite';

/** 仓储传下来的参数可能含 undefined，op-sqlite 只接受 Scalar */
function toScalars(params: unknown[]): OPSQLiteScalar[] {
  return params.map((p) => (p === undefined ? null : (p as OPSQLiteScalar)));
}

/**
 * op-sqlite → core 的同步 SqliteDriver。
 *
 * 两个刻意的取舍：
 * 1. 不用 prepareStatement：它的句柄要靠 finalize 释放，而 SqliteStatement 接口里没有 close，
 *    仓储每次调用都 prepare 会稳定泄漏原生句柄。改成携带 SQL 的薄壳，零泄漏，代价只是丢掉预编译复用。
 * 2. transaction 自己维护嵌套深度：db.transaction 是 async-only，而 core 的接口是同步的；
 *    手写 BEGIN 遇到嵌套会直接抛「cannot start a transaction within a transaction」，
 *    所以内层一律走 SAVEPOINT。
 */
export function makeOpSqliteDriver(db: OPSQLiteDB): SqliteDriver {
  let depth = 0;

  return {
    exec(sql: string): void {
      // 多语句字符串在 op-sqlite 上只会执行第一条，DDL 一律由 migrate 逐条传入；
      // PRAGMA journal_mode 之类会返回结果行的语句同样走这里，忽略返回值即可
      db.executeSync(sql);
    },

    prepare(sql: string): SqliteStatement {
      return {
        run(...params: unknown[]) {
          const r = db.executeSync(sql, toScalars(params));
          return { changes: r.rowsAffected ?? 0, lastInsertRowid: r.insertId ?? 0 };
        },
        get(...params: unknown[]) {
          const r = db.executeSync(sql, toScalars(params));
          return r.rows?.[0];
        },
        all(...params: unknown[]) {
          const r = db.executeSync(sql, toScalars(params));
          return r.rows ?? [];
        },
      };
    },

    transaction<T>(fn: () => T): T {
      const nested = depth > 0;
      const savepoint = `findr_sp_${depth}`;
      depth++;
      db.executeSync(nested ? `SAVEPOINT ${savepoint}` : 'BEGIN');
      try {
        const result = fn();
        db.executeSync(nested ? `RELEASE ${savepoint}` : 'COMMIT');
        return result;
      } catch (e) {
        try {
          if (nested) {
            db.executeSync(`ROLLBACK TO ${savepoint}`);
            db.executeSync(`RELEASE ${savepoint}`);
          } else {
            db.executeSync('ROLLBACK');
          }
        } catch {
          // 回滚本身失败时不要掩盖原始错误，交给上层
        }
        throw e;
      } finally {
        depth--;
      }
    },
  };
}

export function attachPragmas(db: OPSQLiteDB): void {
  // 上次异常退出可能留下未闭合事务，会让后续 BEGIN 直接失败
  try {
    db.executeSync('ROLLBACK');
  } catch {
    // 没有活动事务时 ROLLBACK 会报错，正常情况
  }
  db.executeSync('PRAGMA journal_mode = WAL');
  db.executeSync('PRAGMA foreign_keys = ON');
}

export interface OpenedDb {
  raw: OPSQLiteDB;
  driver: SqliteDriver;
  path: string;
}

export function openFindrDb(name: string = DB_NAME): OpenedDb {
  const raw = open({ name }) as unknown as OPSQLiteDB;
  attachPragmas(raw);
  return { raw, driver: makeOpSqliteDriver(raw), path: raw.getDbPath() };
}
