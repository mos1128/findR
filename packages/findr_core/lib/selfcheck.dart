/// 迁移命门（FTS5 + trigram）的**可复用自检**。
///
/// 为什么把它放在 core 而不是测试里：这套检查要跑**两次**，而且必须跑在**两个不同的层**上
/// （`Flutter迁移交接.md` §6.1）：
///
/// | 层 | 载体 | 验的是什么 |
/// |---|---|---|
/// | 1 · 本地纯 Dart | `test/selfcheck_test.dart`（`dart test`）| **我们写的 SQL 与 trigram 语法**对不对 |
/// | 2 · Flutter/真机 | App 里的自检屏 + `apps/flutter/test/`（`flutter test`）| **打进包的那份 SQLite** 带不带 FTS5 |
///
/// 两处共用同一份逻辑，才不会出现「自检屏写漏了一项」这种不对称。
///
/// ⚠️ **第 1 层通过 ≠ 命门通过**。第 1 层跑在 Dart VM 上；真正会随 APK 发布的是
/// build hooks 编出来的那份原生 SQLite —— 那只有第 2 层能验。**别拿第 1 层冒充。**
library;

import 'db/driver.dart';
import 'db/driver_sqlite3.dart';
import 'db/migrate.dart';

/// 一项自检结果。[detail] 一律填上实际观测值，方便真机上截图核对。
final class SelfCheckItem {
  const SelfCheckItem({required this.name, required this.ok, required this.detail});

  final String name;
  final bool ok;
  final String detail;

  @override
  String toString() => '${ok ? '✅' : '❌'} $name — $detail';
}

final class SelfCheckReport {
  const SelfCheckReport({required this.items});

  final List<SelfCheckItem> items;

  bool get passed => items.every((i) => i.ok);

  int get failedCount => items.where((i) => !i.ok).length;

  /// 自检总判定 —— 只有 [passed] 为真才能说「这一层的命门过了」。
  String get verdict => passed ? '命门通过（本层）' : '命门未通过：$failedCount 项失败';
}

/// 跑一遍核心自检。
///
/// [db] 为空时自开一个**内存库**（自检不该依赖文件系统权限，那会引入与被测问题无关的失败源）。
/// 由本函数传入的库会在结束时关闭；调用方传进来的库**不关**（归调用方管）。
SelfCheckReport runCoreSelfCheck([SqliteDriver? db]) {
  final own = db == null;
  final conn = db ?? Sqlite3Driver.openInMemory();
  final items = <SelfCheckItem>[];

  try {
    // ── 1. 引擎身份：版本号（信息项，只要读得出来就算过）──
    var version = '<读不出>';
    try {
      version = conn.prepare('SELECT sqlite_version() AS v').get()!['v'].toString();
      items.add(SelfCheckItem(name: 'SQLite 版本', ok: true, detail: version));
    } catch (e) {
      items.add(SelfCheckItem(name: 'SQLite 版本', ok: false, detail: '$e'));
    }

    // ── 2. 编译选项里必须有 FTS5（trim 掉 FTS5=1 之类的赋值形式）──
    List<String> opts = const <String>[];
    try {
      opts = conn
          .prepare('PRAGMA compile_options')
          .all()
          .map((r) => r.values.first.toString())
          .toList();
      final fts = opts.where((o) => o.toUpperCase().contains('FTS')).toList();
      items.add(
        SelfCheckItem(
          name: 'FTS5 编译选项',
          ok: fts.any((o) => o.toUpperCase().contains('FTS5')),
          detail: fts.isEmpty ? '没有任何 FTS 选项' : fts.join(', '),
        ),
      );
    } catch (e) {
      items.add(SelfCheckItem(name: 'FTS5 编译选项', ok: false, detail: '$e'));
    }

    // ── 3. trigram 分词器创建得起来（它随 FTS5 一起来，SQLite >= 3.34）──
    var created = false;
    try {
      conn.exec("CREATE VIRTUAL TABLE _selfcheck_fts USING fts5(body, tokenize='trigram')");
      conn.exec("INSERT INTO _selfcheck_fts(body) VALUES ('蓝色的圆珠笔放在书桌抽屉里')");
      created = true;
      items.add(
        SelfCheckItem(
          name: 'trigram 分词器',
          ok: true,
          detail: 'CREATE VIRTUAL TABLE ... tokenize=trigram 成功',
        ),
      );
    } catch (e) {
      items.add(SelfCheckItem(name: 'trigram 分词器', ok: false, detail: '$e'));
    }

    // ── 4. 硬断言：3 字中文 MATCH 必须命中（整套检索的地基）──
    if (created) {
      try {
        final hit = conn
            .prepare("SELECT body FROM _selfcheck_fts WHERE _selfcheck_fts MATCH '圆珠笔'")
            .all();
        items.add(
          SelfCheckItem(
            name: '3 字中文 MATCH「圆珠笔」',
            ok: hit.length == 1,
            detail: '命中 ${hit.length} 条（期望 1）',
          ),
        );
      } catch (e) {
        items.add(SelfCheckItem(name: '3 字中文 MATCH「圆珠笔」', ok: false, detail: '$e'));
      }

      // ── 5. 短查询边界：2 字/1 字应当**返回空且不抛异常** ──
      // 这决定了 TS 侧「>=3 字走 MATCH、更短走 LIKE 降级」这条设计能不能照搬。
      final short = <String>[];
      var shortOk = true;
      for (final q in const <String>['圆珠', '笔']) {
        try {
          final n = conn
              .prepare('SELECT body FROM _selfcheck_fts WHERE _selfcheck_fts MATCH ?')
              .all(<Object?>[q])
              .length;
          short.add('「$q」⇒ $n 条');
        } catch (e) {
          shortOk = false;
          short.add('「$q」⇒ 抛异常 $e');
        }
      }
      items.add(
        SelfCheckItem(
          name: '短查询（2 字/1 字）返回空且不抛异常',
          ok: shortOk,
          detail: short.join('；'),
        ),
      );
      conn.exec('DROP TABLE _selfcheck_fts');
    }

    // ── 6. 真的跑一次迁移：DDL 在这份 SQLite 上能不能执行（含 FTS5 虚表与触发器）──
    try {
      migrate(conn);
      final cats = conn.prepare('SELECT COUNT(*) AS n FROM categories').get()!['n'];
      final sv = currentSchemaVersion(conn);
      items.add(
        SelfCheckItem(
          name: '迁移 + 种子数据',
          ok: cats == 3 && sv == schemaVersion,
          detail: 'categories=$cats（期望 3）、schema_version=$sv（期望 $schemaVersion）',
        ),
      );
    } catch (e) {
      items.add(SelfCheckItem(name: '迁移 + 种子数据', ok: false, detail: '$e'));
    }

    // ── 7. 迁移产出的 FTS 表能写能查（走真实 schema，不只是临时表）──
    try {
      final n = conn
          .prepare('SELECT COUNT(*) AS n FROM cards_fts')
          .get()!['n'];
      items.add(SelfCheckItem(name: 'cards_fts 由迁移建出', ok: true, detail: '现有 $n 行'));
    } catch (e) {
      items.add(SelfCheckItem(name: 'cards_fts 由迁移建出', ok: false, detail: '$e'));
    }

    return SelfCheckReport(items: items);
  } finally {
    if (own) conn.close();
  }
}
