/// 录入条提交契约：**失败时一个素材都不许清**。
///
/// 这条曾经是真 bug：`persistCapture` 抛错后首页只弹一句 toast 就正常返回，
/// Composer 却照常清空输入 —— 用户刚打的字、刚拍的图、刚录的音全从界面上消失。
/// 现在 `onSubmit` 用 `bool` 表达成功/失败，这个文件把它钉住。
library;

import 'dart:async';
import 'dart:io';

import 'package:findr_app/capture/composer.dart';
import 'package:findr_app/platform/app_paths.dart';
import 'package:findr_app/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

late Directory _root;
const _pickerChannel = MethodChannel('plugins.flutter.io/image_picker');

Future<void> _selectPhotos(WidgetTester tester, List<String> paths) async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    _pickerChannel,
    (call) async => call.method == 'pickMultiImage' ? paths : null,
  );
  await tester.tap(find.byTooltip('添加素材'));
  await tester.pumpAndSettle();
  await tester.runAsync(() => tester.tap(find.text('图片')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _pump(
  WidgetTester tester,
  Future<bool> Function(ComposerPayload) onSubmit,
) async {
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _pickerChannel,
      null,
    );
    AppPaths.resetForTest();
    try {
      if (_root.existsSync()) _root.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上偶发句柄未释放，不影响结论
    }
  });

  testWidgets('超量提示在读取原图之前出现', (tester) async {
    await _pump(tester, (_) async => false);
    // 路径尚不可读：若提前读取，这里会显示读图失败而非张数提示。
    await _selectPhotos(tester, List.generate(13, (i) => '${_root.path}/unread-$i.jpg'));
    expect(find.text('图片有点多'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  for (final missing in [false, true]) {
    testWidgets('逐张处理后提交：${missing ? '排除读取失败的附件' : '压缩失败仍保留原图'}', (tester) async {
      final first = File('${_root.path}/first.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 8)));
      final second = File('${_root.path}/second.jpg');
      final raw = <int>[0xff, 0xd8, 0xff, 0xe0, 1, 2, 3];
      if (!missing) second.writeAsBytesSync(raw);
      final submitted = Completer<ComposerPayload>();
      await _pump(tester, (payload) async {
        submitted.complete(payload);
        return false;
      });
      await _selectPhotos(tester, [first.path, second.path]);
      await tester.runAsync(() => tester.tap(find.text('存')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('确认存入'));
      for (var i = 0; i < 500 && !submitted.isCompleted; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(submitted.isCompleted, isTrue);
      final payload = await submitted.future;
      expect(payload.photos, hasLength(missing ? 1 : 2));
      expect(payload.photos.first.isCompressed, isTrue);
      if (!missing) {
        expect(payload.photos.last.isFallback, isTrue);
        expect(payload.photos.last.ext, 'jpg');
        expect(payload.photos.last.bytes, raw);
      }
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

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

  testWidgets('键盘发送：提交期间焦点不丢，键盘不会先关再开', (tester) async {
    final done = Completer<bool>();
    var submitted = 0;
    await _pump(tester, (_) {
      submitted++;
      return done.future;
    });

    await tester.enterText(find.byType(TextField), '护照在主卧抽屉');
    await tester.pump();
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasFocus, isTrue);

    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    expect(submitted, 1);
    expect(
      tester.widget<TextField>(find.byType(TextField)).readOnly,
      isTrue,
      reason: '提交期间应该只读，而不是 disabled',
    );
    expect(
      editable.focusNode.hasFocus,
      isTrue,
      reason: '回车提交后不能 unfocus，否则键盘会先关、保存完再开，闪一下',
    );

    done.complete(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('护照在主卧抽屉'), findsNothing);
  });
}
