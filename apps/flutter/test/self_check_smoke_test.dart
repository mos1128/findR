/// Flutter 侧的冒烟测试。
///
/// ⚠️ **它不等于命门第 2 层**。第 2 层必须在**真机**上跑 `SelfCheckScreen` 才作数
/// （`Flutter迁移交接.md` §6.1）—— 这里跑的仍是 `flutter_tester`，只是把
/// 「界面能起来 + core 能调通 + **那份 SQLite 在 Flutter 工具链下也能开**」串一遍。
///
/// 它真正的价值：
/// ① 挡住「界面接线断了」这类低级错误；
/// ② **暴露「Flutter 端 native assets 没打开」** —— 那种情况下 `package:sqlite3`
///    会退化成去开系统 SQLite（或直接打不开），FTS5 随 APK 一起消失，而 `dart test`
///    是看不出来的（那条路走的是 Dart VM 自己的产物）。
library;

import 'package:findr_app/selfcheck/self_check_screen.dart';
import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('在 Flutter 工具链下跑核心自检，并把明细打出来（CI 里可据日志核对）', () {
    final report = runCoreSelfCheck();
    for (final item in report.items) {
      // ignore: avoid_print
      print(item); // 刻意用 print：要让内容出现在 CI 日志里
    }
    // ignore: avoid_print
    print('判定：${report.verdict}');
    expect(report.passed, isTrue, reason: report.verdict);
  });

  testWidgets('自检屏能起来，并且七项自检全绿', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SelfCheckScreen()));
    await tester.pumpAndSettle();

    // 自检本身抛异常时界面会显示这段文案 —— 单独判它，避免「全绿」被误读。
    expect(find.textContaining('自检本身抛异常'), findsNothing);

    // 只要有一项挂，判定横幅就会变成「未通过」。
    expect(find.textContaining('未通过'), findsNothing);

    // 七项自检的固定项名（数量变化时这条会挂，属于有意为之 —— 少一项就是漏验）。
    for (final name in <String>[
      'SQLite 版本',
      'FTS5 编译选项',
      'trigram 分词器',
      '3 字中文 MATCH「圆珠笔」',
      '短查询（2 字/1 字）返回空且不抛异常',
      '迁移 + 种子数据',
      'cards_fts 由迁移建出',
    ]) {
      expect(find.text(name), findsOneWidget, reason: '缺少自检项：$name');
    }
  });
}
