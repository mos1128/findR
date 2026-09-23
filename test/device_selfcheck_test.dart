/// 设备层自检的自动化测试。
///
/// 存在的理由：设备层那五项里有「媒体文件往返」和「整库打包往返」——
/// 它们**只在真机上才会真的碰文件系统**。如果没有这组测试，那两段代码要等手机装好
/// 才知道写没写对，而出一次包要十几分钟。这里把沙盒根目录钉到一个临时目录上，
/// 于是同一条代码路径能在 `flutter test` 里跑完。
///
/// ⚠️ 它**仍不能替代真机**：Android 的文件系统语义、以及随 APK 发布的那份 SQLite，
/// 只有真机上才算验过（见《开发指南.md》第六节 第 2 层）。
library;

import 'dart:io';

import 'package:findr_app/platform/app_paths.dart';
import 'package:findr_app/platform/db.dart';
import 'package:findr_app/platform/device_selfcheck.dart';
import 'package:findr_core/findr_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory sandbox;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('findr_selfcheck_');
    AppPaths.initWith(sandbox);
    addTearDown(() {
      AppPaths.resetForTest();
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });
  });

  test('设备层五项在真实文件系统上全绿（含媒体往返与整库打包往返）', () async {
    final db = openFindrDb();
    addTearDown(db.close);

    final done = await runDeviceSelfCheck(db: db) as DeviceSelfCheckDone;
    for (final item in done.items) {
      // ignore: avoid_print
      print(item);
    }
    expect(done.passed, isTrue, reason: done.verdict);

    // 五项一项都不能少 —— 漏一项就是漏验一类事（少项时这条会挂，属有意为之）
    expect(done.items.map((i) => i.name).toList(), <String>[
      '真实库文件已打开并挂上 PRAGMA',
      '外键真的会拦人',
      '嵌套事务走 SAVEPOINT（内层回滚不影响外层）',
      '媒体端口真机读写往返（真实文件系统）',
      '整库打包 → 解包 → 读回清单（走完整条导出链路）',
    ]);

    // 库文件真的落在沙盒里（不是内存库），名字就是我们给的那个
    expect(File('${sandbox.path}/$dbFileName').existsSync(), isTrue);

    // 打包那一项要给出真实字节数，否则「走完整条链路」是句空话
    final pack = done.items.last;
    expect(pack.detail, contains('整包 '));
    expect(pack.detail, isNot(contains('整包 0 字节')));
  });

  test('自检不在沙盒里留垃圾（探针文件与临时表都要清掉）', () async {
    final db = openFindrDb();
    addTearDown(db.close);
    await runDeviceSelfCheck(db: db);

    expect(Directory('${sandbox.path}/__selfcheck').existsSync(), isFalse);
    final leftovers = db
        .prepare("SELECT name FROM sqlite_master WHERE name LIKE '__findr_%'")
        .all();
    expect(leftovers, isEmpty, reason: '临时表没清干净：$leftovers');
  });

  test('沙盒没初始化时是「未运行」，不是失败', () async {
    AppPaths.resetForTest();
    final outcome = await runDeviceSelfCheck();
    expect(outcome, isA<DeviceSelfCheckUnavailable>());
    expect((outcome as DeviceSelfCheckUnavailable).reason, contains('沙盒目录尚未初始化'));
  });

  test('内存库上「PRAGMA」那一项必须报错 —— 证明它不是空转', () async {
    // 内存库的 journal_mode 是 memory，不是 wal。这一项要是永远返回绿，
    // 那它在真机上就没有任何信息量。
    final mem = Sqlite3Driver.openInMemory();
    addTearDown(mem.close);
    final done = await runDeviceSelfCheck(db: mem) as DeviceSelfCheckDone;
    final pragma = done.items.firstWhere((i) => i.name == '真实库文件已打开并挂上 PRAGMA');
    expect(pragma.ok, isFalse);
    expect(pragma.detail, contains('journal_mode=memory'));
  });

  test('在还没迁移过的库上也能独立跑（自检自己会迁移）', () async {
    // openFindrDb 只开库、不迁移 —— 自检必须自己补上这一步，否则用户点进来就是一片红
    final db = openFindrDb();
    addTearDown(db.close);
    final done = await runDeviceSelfCheck(db: db) as DeviceSelfCheckDone;
    expect(done.passed, isTrue, reason: done.verdict);
  });

  test('可以反复重跑（上一轮留下的表/文件不会让这一轮假失败）', () async {
    final db = openFindrDb();
    addTearDown(db.close);
    expect((await runDeviceSelfCheck(db: db) as DeviceSelfCheckDone).passed, isTrue);
    expect((await runDeviceSelfCheck(db: db) as DeviceSelfCheckDone).passed, isTrue);
  });
}
