/// 命门自检（第 1 层：本地纯 Dart）—— 逐条对应 `Flutter迁移交接.md` §6.1。
///
/// ⚠️ 它**不能**替代第 2 层（Flutter/真机）—— 那一层验的才是真正打进包的那份 SQLite。
/// 两层的共用逻辑在 `lib/selfcheck.dart`，所以这里只负责「跑一遍 + 硬断言全绿」。
library;

import 'package:findr_core/findr_core.dart';
import 'package:test/test.dart';

void main() {
  test('核心自检在第 1 层（dart test / Dart VM 上的 SQLite）全绿', () {
    final report = runCoreSelfCheck();
    for (final item in report.items) {
      // 把每项实际观测值打出来 —— 真机截图核对时用的是同一份文案
      print(item);
    }
    expect(report.passed, isTrue, reason: report.verdict);
    expect(report.items, isNotEmpty);
  });

  test('SQLite 版本与 FTS5 编译选项（原 fts5_trigram_test 的硬断言，别丢）', () {
    final report = runCoreSelfCheck();
    final version = report.items.firstWhere((i) => i.name == 'SQLite 版本').detail;
    final parts = version.split('.');
    expect(parts.length >= 2, isTrue, reason: '版本号读不出来：$version');
    final major = int.parse(parts[0]);
    final minor = int.parse(parts[1]);
    // trigram 分词器需要 SQLite >= 3.34
    expect(major > 3 || (major == 3 && minor >= 34), isTrue, reason: '版本 = $version');

    expect(
      report.items.firstWhere((i) => i.name == 'FTS5 编译选项').ok,
      isTrue,
      reason: 'FTS5 必须编译进这份 SQLite',
    );
  });

  test('自检对「传进来的库」不负责关闭（归调用方管）', () {
    // 传一个已迁移好的库进去，自检跑完后这个库仍然可用 —— 否则界面里没法复用它做别的检查
    final db = Sqlite3Driver.openInMemory();
    addTearDown(db.close);
    final report = runCoreSelfCheck(db);
    expect(report.passed, isTrue, reason: report.verdict);
    expect(db.prepare('SELECT 1 AS one').get()!['one'], 1);
  });

  test('在「用户用过的库」上仍然全绿 —— 自检不能数全部分类', () {
    // 回归守卫：自检会跑在**真机上的真实库文件**里，那里用户自己加过分类
    // （需求允许自由增删改，预设也可能被删）。
    // 早先的实现数的是 `COUNT(*) FROM categories` 并硬比 3 ——
    // 在真机上必然报错，而且是**假阳性**：会让人以为库坏了，往完全错误的方向排查。
    final db = Sqlite3Driver.openInMemory();
    addTearDown(db.close);
    migrate(db);
    upsertCategory(
      db,
      const Category(
        id: 'cat_user_1',
        name: '自检用的用户分类',
        emoji: '🧪',
        description: null,
        sort: 9,
        isPreset: false,
      ),
    );

    final report = runCoreSelfCheck(db);
    for (final item in report.items) {
      print(item);
    }
    expect(report.passed, isTrue, reason: report.verdict);
    expect(db.prepare('SELECT COUNT(*) AS n FROM categories').get()!['n'], 4);
  });

  test('可以反复重跑（上一轮留下的临时表不会让这一轮假失败）', () {
    final db = Sqlite3Driver.openInMemory();
    addTearDown(db.close);
    expect(runCoreSelfCheck(db).passed, isTrue);
    // 第二遍：若没先 DROP，CREATE VIRTUAL TABLE 会报「table already exists」
    expect(runCoreSelfCheck(db).passed, isTrue);
  });
}
