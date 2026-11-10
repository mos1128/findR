/// 录入条提交契约：**失败时一个素材都不许清**。
///
/// 这条曾经是真 bug：`persistCapture` 抛错后首页只弹一句 toast 就正常返回，
/// Composer 却照常清空输入 —— 用户刚打的字、刚拍的图、刚录的音全从界面上消失。
/// 现在 `onSubmit` 用 `bool` 表达成功/失败，这个文件把它钉住。
library;

import 'dart:io';

import 'package:findr_app/capture/composer.dart';
import 'package:findr_app/platform/app_paths.dart';
import 'package:findr_app/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

late Directory _root;

Future<void> _pump(WidgetTester tester, Future<bool> Function(ComposerPayload) onSubmit) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFindrTheme(Brightness.light),
      home: Scaffold(body: Composer(onSubmit: onSubmit)),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() async {
    _root = await Directory.systemTemp.createTemp('findr_composer_');
    AppPaths.initWith(_root);
  });

  tearDown(() {
    AppPaths.resetForTest();
    try {
      if (_root.existsSync()) _root.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上偶发句柄未释放，不影响结论
    }
  });

  testWidgets('落盘失败：内容保留，能直接重试；成功后才清空', (tester) async {
    var ok = false;
    await _pump(tester, (_) async => ok);

    await tester.enterText(find.byType(TextField), '护照在主卧抽屉');
    await tester.pump();
    await tester.tap(find.text('存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('护照在主卧抽屉'), findsOneWidget, reason: '失败后输入必须还在');
    expect(find.text('没能存下，内容还在，稍后重试'), findsOneWidget);

    ok = true;
    await tester.tap(find.text('存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('护照在主卧抽屉'), findsNothing, reason: '成功后应当清空');
  });
}
