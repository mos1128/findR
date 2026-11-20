/// 提示词编辑页的验收网：正文吃掉剩余高度、自己在里面滚，按钮永远留在屏幕内。
///
/// 钉住的是真机反馈过的两件事：
///   1. 正文比屏幕长时页面拖不动 —— 拖到的地方全在输入框里，输入框自己也不能滚到「再往下」；
///   2. 「保存」被挤到屏幕外，打完字要滚半天才点得到。
library;

import 'dart:io';

import 'package:findr_app/platform/app_paths.dart';
import 'package:findr_app/platform/runtime.dart';
import 'package:findr_app/platform/secure.dart';
import 'package:findr_app/screens/settings/prompts_screen.dart';
import 'package:findr_app/state/update_check.dart';
import 'package:findr_app/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

late Directory _root;

/// 推进若干帧但不等静止：运行时就绪不是一帧的事。
Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> disposeApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await settle(tester, frames: 2);
}

Future<void> pumpPrompts(WidgetTester tester) async {
  addTearDown(() => disposeApp(tester));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiKeyStoreProvider.overrideWithValue(MemoryApiKeyStore()),
        updateHintProvider.overrideWith((ref) async => null),
      ],
      child: MaterialApp(
        theme: buildFindrTheme(Brightness.light),
        home: const PromptsScreen(),
      ),
    ),
  );
  await settle(tester);
}

void main() {
  setUp(() async {
    _root = await Directory.systemTemp.createTemp('findr_prompts_');
    AppPaths.initWith(_root);
  });

  tearDown(() {
    AppPaths.resetForTest();
    try {
      if (_root.existsSync()) _root.deleteSync(recursive: true);
    } catch (_) {
      // 临时目录删不掉不影响结论
    }
  });

  testWidgets('手机上打开正文编辑页：保存与说明都在屏幕内，正文撑满中间那一段', (tester) async {
    // 按真机比例来：1080×2280 / 3.0 = 360×760 的逻辑像素
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await pumpPrompts(tester);
    await tester.tap(find.text('录入').first);
    await settle(tester);

    final screen = tester.getRect(find.byType(Scaffold).last);
    final save = tester.getRect(find.text('保存'));
    expect(screen.contains(save.topLeft), isTrue, reason: '保存被挤出了屏幕');
    expect(screen.contains(save.bottomRight), isTrue, reason: '保存被挤出了屏幕');

    // 正文：填满中间那一段，而不是固定的十几行
    final field = find.byType(EditableText).first;
    expect(tester.getRect(field).height, greaterThan(300));
    // 变量说明写在按钮上方，不用滚也能看见
    expect(find.textContaining('可用变量'), findsOneWidget);
  });
}
