/// 全屏相册（卡片详情里点开照片）的验收网。
///
/// 起因是**真机反馈**：「同一个卡片中的两张图不能左右滑动切换」——
/// 只收一张 `relPath` 的话，想看第二张只能退出去再点缩略图，那不是少个手势，是条死路。
/// 这组用例把三件事钉住：
///
/// 1. 一次拿到**整组**，并且**从点的那张开始**（不是每次都从头）；
/// 2. 左右滑真的翻得动，翻到头会停住；
/// 3. ⚠️ 图上套着可缩放的 `InteractiveViewer`，**它不能把翻页手势吃掉** ——
///    这种「页面看着好好的、就是划不动」只有拖动用例抓得到，肉眼和静态分析都看不出来。
library;

import 'dart:convert';
import 'dart:io';

import 'package:findr_app/platform/app_paths.dart';
import 'package:findr_app/theme/tokens.dart';
import 'package:findr_app/ui/media_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 1×1 的合法 PNG。用例不看像素，只要求「文件真的存在、真的读得出来」。
///
/// 用 `List<int>` 而不是 `Uint8List`：`material.dart` 并不导出后者
/// （只有 `foundation.dart` 那条链上有），而 `writeAsBytesSync` 要的就是 `List<int>`。
final List<int> _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  late Directory sandbox;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('findr_viewer_');
    AppPaths.initWith(sandbox);
    addTearDown(() {
      AppPaths.resetForTest();
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });
  });

  /// 造 n 张**真实存在**的图片，返回它们的相对路径（和 DB 里存的形式一致）。
  List<String> seedImages(int n) {
    final out = <String>[];
    for (var i = 1; i <= n; i++) {
      final rel = 'files/cards/202609/c1/${i.toString().padLeft(2, '0')}.webp';
      File(AppPaths.abs(rel))
        ..createSync(recursive: true)
        ..writeAsBytesSync(_pngBytes);
      out.add(rel);
    }
    return out;
  }

  /// 打开相册：界面上只有一颗按钮，点它等价于在卡片详情里点某张缩略图。
  Future<void> openViewer(
    WidgetTester tester,
    List<String> paths, {
    int initialIndex = 0,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFindrTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () =>
                    openImageViewer(context, paths, initialIndex: initialIndex),
                child: const Text('点我'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('点我'));
    await tester.pumpAndSettle();
  }

  /// 模拟「用手指划一下」。
  ///
  /// ⚠️ 必须用 `fling`（带速度），**不要用 `tester.drag`**：`drag` 收尾时速度是 0，
  /// 而 PageView 恰好拖到半页时会**回弹**，于是「明明划了却没翻页」——
  /// 那是测试造出来的假象，会让人误判成「手势被吃掉了」而跑去改根本没坏的代码。
  Future<void> swipe(WidgetTester tester, double dx) async {
    await tester.fling(find.byType(PageView), Offset(dx, 0), 900);
    await tester.pumpAndSettle();
  }

  testWidgets('三张图：标题给出页码，打开就是第 1 张', (tester) async {
    await openViewer(tester, seedImages(3));

    expect(find.byType(PageView), findsOneWidget);
    expect(find.text('查看图片（1 / 3）'), findsOneWidget);
  });

  testWidgets('只有一张时不显示页码（没有可翻的页，数字只是噪音）', (tester) async {
    await openViewer(tester, seedImages(1));

    expect(find.byType(PageView), findsOneWidget);
    expect(find.text('查看图片'), findsOneWidget);
    expect(find.textContaining('/'), findsNothing);
  });

  testWidgets('点第 3 张就**从第 3 张开始**，不是每次都从头', (tester) async {
    await openViewer(tester, seedImages(5), initialIndex: 2);

    expect(find.text('查看图片（3 / 5）'), findsOneWidget);
  });

  testWidgets('左滑翻到下一张 —— 正是真机报的那一条', (tester) async {
    await openViewer(tester, seedImages(3));
    expect(find.text('查看图片（1 / 3）'), findsOneWidget);

    await swipe(tester, -400);
    expect(find.text('查看图片（2 / 3）'), findsOneWidget);

    await swipe(tester, -400);
    expect(find.text('查看图片（3 / 3）'), findsOneWidget);
  });

  testWidgets('右滑翻回上一张', (tester) async {
    await openViewer(tester, seedImages(3), initialIndex: 2);
    expect(find.text('查看图片（3 / 3）'), findsOneWidget);

    await swipe(tester, 400);
    expect(find.text('查看图片（2 / 3）'), findsOneWidget);
  });

  testWidgets('翻到头就停住，不会翻过头（也不报错）', (tester) async {
    await openViewer(tester, seedImages(2));

    await swipe(tester, -400);
    expect(find.text('查看图片（2 / 2）'), findsOneWidget);

    await swipe(tester, -400); // 已经是最后一张，不该冒出「3 / 2」
    expect(find.text('查看图片（2 / 2）'), findsOneWidget);
  });

  testWidgets('⚠️ 图上那层可缩放的 InteractiveViewer 不能把翻页手势吃掉', (tester) async {
    await openViewer(tester, seedImages(4));

    // 直接在**图片那一层上**甩动（不是甩标题栏、也不是甩空白处）——
    // 手势争用只有真正压住 InteractiveViewer 的时候才会暴露。
    await tester.fling(
      find.byType(InteractiveViewer).first,
      const Offset(-400, 0),
      900,
    );
    await tester.pumpAndSettle();

    expect(find.text('查看图片（2 / 4）'), findsOneWidget);
  });

  testWidgets('图片读不出来时，每一页仍占住自己那一页（总数不会缩水）', (tester) async {
    // 沙盒未就绪 ⇒ mediaFileOf 一律返回 null，三张图全读不出来
    AppPaths.resetForTest();

    await openViewer(tester, <String>[
      'files/cards/a/01.webp',
      'files/cards/a/02.webp',
      'files/cards/a/03.webp',
    ], initialIndex: 1);

    expect(find.text('查看图片（2 / 3）'), findsOneWidget);
    // 读不出来也要能翻：否则「第 2 张丢了」会被当成「后面都没了」
    await swipe(tester, -400);
    expect(find.text('查看图片（3 / 3）'), findsOneWidget);
  });

  testWidgets('起始下标过大：夹到最后一张，而不是开出一个空页', (tester) async {
    await openViewer(tester, seedImages(2), initialIndex: 99);

    expect(find.text('查看图片（2 / 2）'), findsOneWidget);
  });

  testWidgets('起始下标为负：夹到第一张', (tester) async {
    await openViewer(tester, seedImages(2), initialIndex: -5);

    expect(find.text('查看图片（1 / 2）'), findsOneWidget);
  });

  testWidgets('一张都没有时，点开不该推一个空的全屏页进去', (tester) async {
    await openViewer(tester, const <String>[]);

    expect(find.byType(PageView), findsNothing);
    expect(find.text('点我'), findsOneWidget); // 还停在原来那屏
  });
}
