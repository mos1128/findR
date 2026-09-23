// 驱动层测试。
//
// `Sqlite3Driver` 是**我们自己写的代码**，所以必须有押注：
//   - `exec` 能不能跑多语句（schema 里那三个 trigger 体带分号，靠的就是这个）；
//   - `run` 的 changes / lastInsertRowid 对不对；
//   - `transaction` 的提交、回滚、以及**嵌套**（内层走 SAVEPOINT）。
// 最后一条最容易写错：手写 BEGIN 遇到嵌套会直接抛
// 「cannot start a transaction within a transaction」，而 taxonomy / repository 里
// 确实存在事务套事务的调用。

import 'package:findr_core/findr_core.dart';
import 'package:test/test.dart';

import '../helpers.dart';

int _countLocations(SqliteDriver db) =>
    db.prepare('SELECT COUNT(*) AS n FROM locations').get()!['n']! as int;

void _insertLocation(SqliteDriver db, String id, String name) {
  db
      .prepare('INSERT INTO locations (id, name) VALUES (?, ?)')
      .run([id, name]);
}

void main() {
  test('attachPragmas：foreign_keys 被开启，且对空库执行不抛异常', () {
    // 首次挂 PRAGMA 时会先跑一次 ROLLBACK（防上次异常退出的残留事务），
    // 空库上那次 ROLLBACK 必然报错 —— 必须被吞掉，不能冒到调用方。
    final db = Sqlite3Driver.openInMemory();
    addTearDown(db.close);

    expect(db.prepare('PRAGMA foreign_keys').get(), {'foreign_keys': 1});
    // 挂上 PRAGMA 之后，外键是真的在生效：引用不存在的分类必须被拒
    migrate(db);
    expect(
      () => db
          .prepare(
            'INSERT INTO cards (id, status, category_id, created_at, updated_at) '
            "VALUES ('x','active','不存在的分类','t','t')",
          )
          .run(),
      throwsA(anything),
      reason: 'foreign_keys = ON 时，指向不存在分类的卡片必须插不进去',
    );
  });

  test('exec：无参数时能一次执行多条语句', () {
    final db = Sqlite3Driver.openInMemory();
    addTearDown(db.close);

    db.exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
    db.exec("INSERT INTO t (v) VALUES ('a'); INSERT INTO t (v) VALUES ('b');");

    expect(db.prepare('SELECT COUNT(*) AS n FROM t').get()!['n'], 2);
  });

  test('run：返回受影响行数与 lastInsertRowid', () {
    final db = makeDb();
    addTearDown(db.close);

    final inserted = db
        .prepare('INSERT INTO locations (id, parent_id, name, sort) VALUES (?, ?, ?, ?)')
        .run(['l1', null, '主卧', 0]);
    expect(inserted.changes, 1);
    expect(inserted.lastInsertRowid, greaterThan(0));

    final updated = db
        .prepare('UPDATE locations SET name = ? WHERE id = ?')
        .run(['主卧室', 'l1']);
    expect(updated.changes, 1);

    final missed = db
        .prepare('UPDATE locations SET name = ? WHERE id = ?')
        .run(['x', '不存在']);
    expect(missed.changes, 0);
  });

  test('get：无结果返回 null，all：无结果返回空表', () {
    final db = makeDb();
    addTearDown(db.close);

    expect(db.prepare('SELECT * FROM locations WHERE id = ?').get(['无']), isNull);
    expect(db.prepare('SELECT * FROM locations').all(), isEmpty);
  });

  test('transaction：正常路径提交，抛异常时整体回滚', () {
    final db = makeDb();
    addTearDown(db.close);

    db.transaction(() {
      _insertLocation(db, 'a', 'A');
      _insertLocation(db, 'b', 'B');
    });
    expect(_countLocations(db), 2);

    expect(
      () => db.transaction(() {
        _insertLocation(db, 'c', 'C');
        _insertLocation(db, 'd', 'D');
        throw StateError('boom');
      }),
      throwsStateError,
    );
    expect(_countLocations(db), 2, reason: '整个事务必须回滚');
    // 回滚之后连接仍然可用
    _insertLocation(db, 'e', 'E');
    expect(_countLocations(db), 3);
  });

  test('transaction：嵌套走 SAVEPOINT —— 内层失败只回滚内层，外层照样提交', () {
    final db = makeDb();
    addTearDown(db.close);

    db.transaction(() {
      _insertLocation(db, 'a', 'A');
      expect(
        () => db.transaction(() {
          _insertLocation(db, 'b', 'B');
          throw StateError('inner');
        }),
        throwsStateError,
      );
      // 内层已回滚，外层还能继续写
      _insertLocation(db, 'c', 'C');
    });

    expect(
      db.prepare('SELECT id FROM locations ORDER BY id').all().map((r) => r['id']),
      ['a', 'c'],
      reason: 'b 属于失败的内层，必须消失；a / c 属于外层，必须留下',
    );
  });
}
