import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'driver.dart';

/// `package:sqlite3` → core 的 `SqliteDriver` 实现。
///
/// 取舍与驱动接口那层保持一致：
///
/// 1. **不持有预编译语句**：`prepare` 返回的是只带 SQL 的薄壳，每次调用走
///    `Database.execute` / `Database.select`（内部 prepare 后立刻释放）。
///    代价是丢掉预编译复用，换来的是仓储里随便 prepare 都不会泄漏原生句柄。
/// 2. **transaction 自己维护嵌套深度**：内层走 SAVEPOINT，而不是再 BEGIN 一次。
final class Sqlite3Driver implements SqliteDriver {
  Sqlite3Driver(this._db, {this.path});

  /// 打开库文件（不存在则创建），并挂好 PRAGMA。
  factory Sqlite3Driver.open(String path) {
    final driver = Sqlite3Driver(sqlite.sqlite3.open(path), path: path);
    driver.attachPragmas();
    return driver;
  }

  /// 打开内存库（测试用）。PRAGMA 照挂 —— 与真机保持同一套设置，
  /// 免得出现「本地测试全绿、真机 insert 被外键拒」的不对称。
  factory Sqlite3Driver.openInMemory() {
    final driver = Sqlite3Driver(sqlite.sqlite3.openInMemory());
    driver.attachPragmas();
    return driver;
  }

  final sqlite.Database _db;

  /// 库文件路径；内存库为 null（自检屏要显示它，故留一个字段）。
  final String? path;

  int _depth = 0;

  /// 底层句柄。仅供平台侧做开库/关库之类的事，业务代码不要碰。
  sqlite.Database get raw => _db;

  @override
  void exec(String sql) {
    // 无参数 ⇒ `package:sqlite3` 走 sqlite3_exec：可执行多条语句，
    // 且 trigger 体里的分号不会被误切。
    _db.execute(sql);
  }

  @override
  SqliteStatement prepare(String sql) => _Shell(_db, sql);

  @override
  T transaction<T>(T Function() fn) {
    final nested = _depth > 0;
    final savepoint = 'findr_sp_$_depth';
    _depth++;
    exec(nested ? 'SAVEPOINT $savepoint' : 'BEGIN');
    try {
      final result = fn();
      exec(nested ? 'RELEASE $savepoint' : 'COMMIT');
      return result;
    } catch (_) {
      try {
        if (nested) {
          exec('ROLLBACK TO $savepoint');
          exec('RELEASE $savepoint');
        } else {
          exec('ROLLBACK');
        }
      } catch (_) {
        // 回滚本身失败时不要掩盖原始错误，交给上层
      }
      rethrow;
    } finally {
      _depth--;
    }
  }

  ///
  /// 先 ROLLBACK：上次异常退出可能留下未闭合事务，那会让后续 `BEGIN` 直接失败。
  void attachPragmas() {
    try {
      exec('ROLLBACK');
    } catch (_) {
      // 没有活动事务时 ROLLBACK 会报错，属正常情况
    }
    exec('PRAGMA journal_mode = WAL');
    exec('PRAGMA foreign_keys = ON');
  }

  @override
  void close() => _db.close();
}

/// 只带 SQL 的语句薄壳。见类注释第 1 条取舍。
final class _Shell implements SqliteStatement {
  _Shell(this._db, this._sql);

  final sqlite.Database _db;
  final String _sql;

  @override
  ({int changes, int lastInsertRowid}) run([List<Object?> params = const []]) {
    _db.execute(_sql, params);
    return (changes: _db.updatedRows, lastInsertRowid: _db.lastInsertRowId);
  }

  @override
  Map<String, Object?>? get([List<Object?> params = const []]) {
    final rows = _db.select(_sql, params);
    return rows.isEmpty ? null : rows.first;
  }

  @override
  List<Map<String, Object?>> all([List<Object?> params = const []]) =>
      _db.select(_sql, params);
}
