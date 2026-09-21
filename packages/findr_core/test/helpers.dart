import 'package:findr_core/findr_core.dart';

/// 与 TS 的 `test/helpers.ts` 的 `makeDb()` 同源：开一个内存库并跑完迁移。
///
/// 用内存库而不是临时文件：每次都从零开始，且不碰磁盘 —— 与 TS 侧 `new Database(':memory:')`
/// 完全一致的行为（`PRAGMA journal_mode = WAL` 在内存库上会被 SQLite 忽略，无副作用）。
SqliteDriver makeDb() {
  final db = Sqlite3Driver.openInMemory();
  migrate(db);
  return db;
}

/// 取某张表的列名（PRAGMA table_info 的 name 列）。
List<String> columnsOf(SqliteDriver db, String table) => db
    .prepare('PRAGMA table_info($table)')
    .all()
    .map((r) => r['name']!.toString())
    .toList();

/// 取 sqlite_master 里某类对象的名字。
List<String> objectsOf(SqliteDriver db, String type) => db
    .prepare('SELECT name FROM sqlite_master WHERE type = ?')
    .all([type])
    .map((r) => r['name']!.toString())
    .toList();
