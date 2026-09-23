import 'driver.dart';
import 'schema.dart';

/// 迁移链的一个版本 = 一组「一条 DDL 一个元素」的语句，按数组顺序执行。
///
/// `withoutForeignKeys` 是给「重建表」用的：只要脚本里出现 DROP TABLE + RENAME 来改表结构，
/// 而该表被别的表外键引用（cards.category_id → categories），开着外键的 DROP 会触发隐式
/// 删除并被约束拒绝。SQLite 官方的改表流程也要求先关外键、改完再开回来。
final class _Migration {
  const _Migration(this.name, this.statements, {this.withoutForeignKeys = false});

  /// 只用于报错定位
  final String name;
  final List<String> statements;
  final bool withoutForeignKeys;
}

/// 迁移链。**只追加，不修改已发布的历史条目**（见 schema.dart 顶部的迁移纪律）。
/// 数组长度即 `schemaVersion` —— 备份包导入时用它挡住「包里比我新」的情况。
const List<_Migration> _migrations = <_Migration>[
  _Migration('v1-initial', schemaV1Statements),
  _Migration(
    'v2-drop-structure-and-schedule-fields',
    v2Statements,
    withoutForeignKeys: true,
  ),
];

final int schemaVersion = _migrations.length;

/// 读出库存的 schema_version（未建库返回 0）。备份导出用它给 manifest 打标。
///
/// ⚠️ 刻意不做宽松的数字转换：读出坏值会得到一个非数字（后续比较全 false，
/// 等于「什么都不迁、只把版本号覆写掉」）。这里 `int.tryParse` 失败一律当 0，
/// 也就是**宁可重跑一遍迁移**。安全性来自 v1 全 `IF NOT EXISTS`、v2 也可重复执行 —— 已由
/// `test/db/migrate_test.dart` 的幂等用例钉住。
int currentSchemaVersion(SqliteDriver db) {
  final table = db
      .prepare(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'schema_meta'",
      )
      .get();
  if (table == null) return 0;
  final row = db
      .prepare("SELECT value FROM schema_meta WHERE key = 'schema_version'")
      .get();
  final value = row?['value'];
  if (value == null) return 0;
  return int.tryParse(value.toString()) ?? 0;
}

bool _foreignKeysEnabled(SqliteDriver db) {
  final row = db.prepare('PRAGMA foreign_keys').get();
  return row?['foreign_keys'] == 1;
}

/// 单个版本：整体一个事务（SQLite 的 DDL 是事务性的），需要时临时关外键。
void _runMigration(SqliteDriver db, _Migration migration) {
  final restoreFk = migration.withoutForeignKeys && _foreignKeysEnabled(db);
  // PRAGMA 在事务内是空操作，必须在 BEGIN 之前执行
  if (migration.withoutForeignKeys) db.exec('PRAGMA foreign_keys = OFF');
  try {
    db.transaction(() {
      for (final statement in migration.statements) {
        db.exec(statement);
      }
    });
    if (migration.withoutForeignKeys) {
      // 重建期间外键是关的，这里显式查一遍，别把引用错误拖到运行期才炸
      final bad = db.prepare('PRAGMA foreign_key_check').all();
      if (bad.isNotEmpty) {
        throw StateError(
          '迁移后存在外键违规（${migration.name}）：${bad.length} 行',
        );
      }
    }
  } finally {
    if (restoreFk) db.exec('PRAGMA foreign_keys = ON');
  }
}

void migrate(SqliteDriver db) {
  db.exec(
    'CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  );
  final current = currentSchemaVersion(db);
  for (var i = current; i < _migrations.length; i++) {
    _runMigration(db, _migrations[i]);
  }
  db
      .prepare(
        "INSERT INTO schema_meta (key, value) VALUES ('schema_version', ?) "
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      )
      .run([_migrations.length.toString()]);
  // 只在首次建库时播种：分类是完整 CRUD 的对象，每次开库重跑会让删掉的预设分类复活
  if (current == 0) {
    for (final statement in seedStatements) {
      db.exec(statement);
    }
  }
}
