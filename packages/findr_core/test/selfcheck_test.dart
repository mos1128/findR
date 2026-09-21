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
}
