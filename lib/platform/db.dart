/// 打开真机上的库文件 —— 对应 RN 的 `apps/mobile/src/platform/db.ts`。
///
/// 那一层在 RN 侧做的是「op-sqlite → core 的同步 SqliteDriver」适配；
/// Dart 侧这层适配已经在 core 里了（`db/driver_sqlite3.dart`，含嵌套事务走 SAVEPOINT 与
/// `attachPragmas` 里的 `WAL` + `foreign_keys`），所以这里只剩「路径怎么来」这一件事。
library;

import 'package:findr_core/findr_core.dart';

import 'app_paths.dart';

/// 与 RN 版同名（`apps/mobile/src/platform/db.ts` 的 `DB_NAME`）。
/// 同名只为了将来对照备份/迁移方便 —— 两个 App 的沙盒本来就是分开的
/// （Flutter 版 applicationId 是 `com.findr.app.dev`）。
const String dbFileName = 'findr.sqlite';

/// 打开库文件（不存在则创建），PRAGMA 由 `Sqlite3Driver.open` 挂好。
Sqlite3Driver openFindrDb([String name = dbFileName]) =>
    Sqlite3Driver.open(AppPaths.abs(name));

/// 打开 + 迁移。整个 App 只该开一次（反复开关库文件会明显增加启动延迟）。
Sqlite3Driver openAndMigrateDb([String name = dbFileName]) {
  final db = openFindrDb(name);
  migrate(db);
  return db;
}

/// 库文件的绝对路径（自检屏 / 设置页要显示它，方便排查）。
String dbPathFor([String name = dbFileName]) => AppPaths.abs(name);
