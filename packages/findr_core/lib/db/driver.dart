/// 驱动接口 —— 与 `packages/core/src/db/driver.ts` 一一对应。
///
/// TS 侧是「node 测试用 better-sqlite3 / App 内用 op-sqlite」的双实现；
/// Dart 侧**不需要双实现**：`package:sqlite3` 3.x 用 Dart build hooks 自带预编译 SQLite
/// （全平台同一份产物，默认编译选项含 `SQLITE_ENABLE_FTS5`）⇒ 测试与真机跑的是同一份实现，
/// 不会出现「本地测试全绿、真机上 SQL 行为不同」的不对称。
///
/// 接口刻意保持 TS 的形状（`exec` / `prepare` / `transaction`），目的是让
/// `repository.ts`（648 行）的翻译保持机械：
/// `db.prepare(sql).get(x)` ⇒ `db.prepare(sql).get([x])`。
/// **唯一的语法差异是 Dart 没有变长参数**，参数一律包成一个列表传入。
library;

/// 一条可执行语句的薄壳，与 TS 的 `SqliteStatement` 同形。
///
/// 注意它**不持有原生句柄**：`exec`/`get`/`all` 每次都走驱动的
/// `execute` / `select`（内部 prepare 后即刻释放）⇒ 零泄漏。
/// TS 侧因为接口里没有 close，刻意放弃了预编译复用；Dart 这边沿用同一取舍，
/// 换来的是「仓储里随便 prepare 都不会漏」，以及接口的绝对简单。
abstract interface class SqliteStatement {
  /// 写语句。返回受影响行数与最后插入的 rowid（对应 TS 的 `{changes, lastInsertRowid}`）。
  ({int changes, int lastInsertRowid}) run([List<Object?> params]);

  /// 取第一行；无结果时返回 null（对应 TS 的 `get`）。
  Map<String, Object?>? get([List<Object?> params]);

  /// 取全部行（对应 TS 的 `all`）。
  List<Map<String, Object?>> all([List<Object?> params]);
}

abstract interface class SqliteDriver {
  /// 执行 SQL，忽略结果行。对应 TS 的 `db.exec`。
  ///
  /// **可含多条语句**：`package:sqlite3` 在无参数时走 `sqlite3_exec`，
  /// 因此 trigger 体里的分号不会被误切 —— schema 里那三个 `CREATE TRIGGER` 依赖这一点。
  /// （TS 侧 op-sqlite 只能执行多语句的第一条，所以 schema 才拆成「一条 DDL 一个数组元素」；
  /// 这个数组形状在 Dart 侧保留，一是 v1 已冻结，二是逐条执行能把报错定位到具体语句。）
  void exec(String sql);

  SqliteStatement prepare(String sql);

  /// 事务。**必须支持嵌套** —— 内层走 SAVEPOINT。
  ///
  /// TS 侧的 op-sqlite 驱动就是这么做的（见 `apps/mobile/src/platform/db.ts`）：
  /// `taxonomy` / `repository` 里存在事务套事务的调用，手写 `BEGIN` 遇到嵌套会直接抛
  /// 「cannot start a transaction within a transaction」。
  T transaction<T>(T Function() fn);

  /// 关闭连接。
  ///
  /// **这是相对 TS 接口唯一的新增**（那边关的是平台侧的 raw 句柄，核心不碰）。
  /// Dart 侧 core 自带实现、且 App 需要在生命周期结束时收干净，所以把它收进接口。
  void close();
}
