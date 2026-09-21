// 迁移命门验证（Flutter迁移交接.md 第 6.0 节 · 第 1 层：本地纯 Dart）
//
// 我们整套检索（L1 FTS5 本地检索）建立在「FTS5 + trigram 分词器」上。
// 这个测试验的是：**我们写的 SQL 与 trigram 语法本身没问题**。
//
// ⚠️ 它**不能**替代第 2 层（真机自检屏）——那一层验的才是真正打进 APK 的那份 SQLite。
//    别只做这一层就宣布命门通过。

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('SQLite 版本与 FTS5 编译选项', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);

    final version =
        db.select('SELECT sqlite_version() AS v').first['v'] as String;
    print('SQLite version = $version');

    final opts = db
        .select('PRAGMA compile_options')
        .map((r) => r['compile_options'] as String)
        .toList();
    final fts = opts.where((o) => o.toUpperCase().contains('FTS')).toList();
    print('FTS 相关编译选项 = $fts');

    expect(
      opts.any((o) => o.toUpperCase().contains('FTS5')),
      isTrue,
      reason: 'FTS5 必须编译进这份 SQLite',
    );

    // trigram 分词器随 FTS5 一起来（SQLite 3.34+），版本低于 3.34 就没有。
    final major = int.parse(version.split('.')[0]);
    final minor = int.parse(version.split('.')[1]);
    expect(
      major > 3 || (major == 3 && minor >= 34),
      isTrue,
      reason: 'trigram 分词器需要 SQLite >= 3.34',
    );
  });

  test('FTS5 + trigram：3 字以上中文 MATCH 必须命中（硬断言）', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);

    db.execute(
      "CREATE VIRTUAL TABLE cards_fts USING fts5(body, tokenize='trigram')",
    );
    db.execute("INSERT INTO cards_fts(body) VALUES ('蓝色的圆珠笔放在书桌抽屉里')");

    final hit = db.select(
      "SELECT body FROM cards_fts WHERE cards_fts MATCH '圆珠笔'",
    );
    print('3 字查询「圆珠笔」命中 ${hit.length} 条');

    expect(
      hit.length,
      1,
      reason: '这是整套检索的地基：trigram 下 3 字以上中文必须能命中',
    );
  });

  test('trigram 的短查询边界（表征，不硬断言）', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);

    db.execute("CREATE VIRTUAL TABLE t USING fts5(body, tokenize='trigram')");
    db.execute("INSERT INTO t(body) VALUES ('圆珠笔')");

    // TS 侧的设计是「>=3 字走 MATCH，更短的走 LIKE 降级」。
    // 这里只把真实行为打出来，供核对降级策略是否必要 / 是否有异常。
    for (final q in ['圆珠', '笔']) {
      try {
        final rs = db.select("SELECT body FROM t WHERE t MATCH ?", [q]);
        print('${q.length} 字查询「$q」⇒ 命中 ${rs.length} 条（无异常）');
      } catch (e) {
        print('${q.length} 字查询「$q」⇒ 抛异常：$e');
      }
    }
  });
}
