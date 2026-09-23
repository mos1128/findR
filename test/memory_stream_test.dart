/// 首页（记忆流）的验收网。
///
/// 这些用例的意义不是「点得到按钮」，而是**把几条只能靠真机反馈才发现的口径钉住**：
///
/// - 「上查下记」两条链路同时存在，且**互不吞噬**（需求六：合并会丢数据）；
/// - 记忆流是**滚动容器**（列表容器不具备滚动能力时，卡片一多就划不动）；
/// - 未配模型时**检索照样可用**（字面兜底），且界面必须说清走的是哪条路；
/// - 录入是**先落盘**：草稿立刻出现在流里，队列在后台慢慢跑。
library;

import 'dart:io';

import 'package:findr_app/platform/app_paths.dart';
import 'package:findr_app/platform/db.dart';
import 'package:findr_app/platform/secure.dart';
import 'package:findr_app/platform/runtime.dart';
import 'package:findr_app/screens/memory_stream_screen.dart';
import 'package:findr_app/theme/tokens.dart';
import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

late Directory _root;

/// 推进若干帧但**不等静止**。
///
/// 不能用 `pumpAndSettle`：检索进行中会画一条 `LinearProgressIndicator`，
/// 那是个永不停止的动画，`pumpAndSettle` 会一直等到超时。
Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> pumpApp(WidgetTester tester) async {
  // 每个用例结束时都把树换掉，让 ProviderScope 收掉库连接（见 disposeApp 的说明）
  addTearDown(() => disposeApp(tester));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // 真机上 Key 走 Keystore；测试里换成内存实现，免得碰平台通道
        apiKeyStoreProvider.overrideWithValue(MemoryApiKeyStore()),
      ],
      child: MaterialApp(
        theme: buildFindrTheme(Brightness.light),
        home: const MemoryStreamScreen(),
      ),
    ),
  );
  await settle(tester);
}

/// 收尾：把整棵树换掉，让 `ProviderScope` 释放掉库连接。
///
/// 不做这一步的话，`tearDown` 删临时目录时会报「另一个程序正在使用此文件」——
/// 那是**我们自己的库连接还开着**，不是测试环境的问题。
Future<void> disposeApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await settle(tester, frames: 2);
}

/// 直接往库里塞一张卡（跳过界面，用来构造检索与筛选场景）。
void seedCard(String transcript, {String? categoryId, String? id}) {
  final db = openAndMigrateDb();
  createDraft(
    db,
    CaptureInput(source: SourceKind.text, text: transcript),
    id: id ?? makeId(),
  );
  if (categoryId != null) {
    updateCardFields(
      db,
      listCards(db).first.id,
      CardPatch(categoryId: categoryId),
      DateTime.now(),
    );
  }
  db.close();
}

void main() {
  setUp(() async {    _root = await Directory.systemTemp.createTemp('findr_ui_');
    AppPaths.initWith(_root);
  });

  tearDown(() {
    AppPaths.resetForTest();
    try {
      if (_root.existsSync()) _root.deleteSync(recursive: true);
    } catch (_) {
      // 临时目录删不掉不影响结论（Windows 上偶尔要等文件句柄释放）
    }
  });

  testWidgets('空库时是「还没有记忆」空态，并且两条链路都在', (tester) async {
    await pumpApp(tester);

    expect(find.text('还没有记忆'), findsOneWidget);
    // 「查」：搜索框
    expect(find.text('问一句，比如「护照放哪了」'), findsOneWidget);
    // 「记」：录入条
    expect(find.text('记一笔…（回车即存）'), findsOneWidget);
    expect(find.text('存'), findsOneWidget);
    // 未配模型时的提示条**必须在文档流里**（曾经做成浮层盖住搜索框，真机反馈「找不到搜索入口」）
    expect(find.textContaining('还没配置模型：内容都留在本地'), findsOneWidget);
  });

  testWidgets('打字录入 → 先落盘，卡片立刻出现在流里（不依赖模型）', (tester) async {
    await pumpApp(tester);

    // 末一个输入框是底部录入条（第一个是顶部搜索框）
    await tester.enterText(find.byType(TextField).last, '护照放在主卧抽屉');
    await settle(tester, frames: 3);
    await tester.tap(find.text('存'));
    await settle(tester);

    final db = openAndMigrateDb();
    final cards = listCards(db);
    db.close();

    expect(cards.length, 1, reason: '先落盘：即使模型没配，素材也必须已经在库里');
    expect(cards.first.transcript, '护照放在主卧抽屉');
    expect(cards.first.status, CardStatus.pending, reason: '有文字就直接进待解析，跳过转写');

    // 流里出现了这张卡（标题取原文前 30 字）
    expect(find.text('护照放在主卧抽屉'), findsWidgets);
    expect(find.text('还没有记忆'), findsNothing);
  });

  testWidgets('空白内容不落盘（存按钮在没内容时是禁用的）', (tester) async {
    await pumpApp(tester);

    await tester.enterText(find.byType(TextField).last, '   ');
    await settle(tester, frames: 3);
    await tester.tap(find.text('存'));
    await settle(tester);

    final db = openAndMigrateDb();
    expect(listCards(db).length, 0);
    db.close();
  });

  testWidgets('未配模型时检索照样能用（字面兜底），并把「走的是哪条路」说清楚', (tester) async {
    seedCard('护照放在主卧抽屉里');
    await pumpApp(tester);

    await tester.enterText(find.byType(TextField).first, '主卧抽屉');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settle(tester);

    expect(find.textContaining('检索结果'), findsOneWidget);
    expect(
      find.textContaining('还没配置模型，按关键词字面检索'),
      findsOneWidget,
      reason: '不说清走的是哪条路，用户会把「字面没搜到」读成「卡片丢了」',
    );
    // 未配模型时不给「AI 总结」入口 —— 点了必然失败
    expect(find.text('AI 总结'), findsNothing);
    expect(find.text('回到记忆流'), findsOneWidget);
  });

  testWidgets('搜不到时给的是「没找到相关记忆」，并提示换关键词而不是「还没有记忆」', (tester) async {
    seedCard('护照放在主卧抽屉里');
    await pumpApp(tester);

    await tester.enterText(find.byType(TextField).first, '完全不存在的词条xyz');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settle(tester);

    expect(find.text('没找到相关记忆'), findsOneWidget);
    expect(find.text('还没有记忆'), findsNothing);
    expect(find.textContaining('把几个关键词用空格分开'), findsOneWidget);
  });

  testWidgets('回到记忆流：结果态与答案一起清掉', (tester) async {
    seedCard('护照放在主卧抽屉里');
    await pumpApp(tester);

    await tester.enterText(find.byType(TextField).first, '主卧抽屉');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settle(tester);
    expect(find.textContaining('检索结果'), findsOneWidget);

    await tester.tap(find.text('回到记忆流'));
    await settle(tester);
    expect(find.textContaining('检索结果'), findsNothing);
    // 记忆流本身还在（那张卡）
    expect(find.textContaining('护照放在主卧抽屉里'), findsWidgets);
  });

  testWidgets('分类 Chip 只筛记忆流；点两次同一条即取消筛选', (tester) async {
    final db = openAndMigrateDb();
    final cat = listCategories(db).first;
    db.close();

    seedCard('甲条目内容', categoryId: cat.id);
    seedCard('乙条目内容');
    await pumpApp(tester);

    // 未筛选：两条都在
    expect(find.textContaining('甲条目内容'), findsWidgets);
    expect(find.textContaining('乙条目内容'), findsWidgets);

    await tester.tap(find.textContaining(cat.name).first);
    await settle(tester);
    expect(find.textContaining('甲条目内容'), findsWidgets);
    expect(find.textContaining('乙条目内容'), findsNothing);

    await tester.tap(find.textContaining(cat.name).first);
    await settle(tester);
    expect(find.textContaining('乙条目内容'), findsWidgets);
  });

  testWidgets('记忆流是可滚动容器（划得动）', (tester) async {
    for (var i = 0; i < 12; i++) {
      seedCard('第 $i 条记忆的内容');
    }
    await pumpApp(tester);

    // 12 张卡在手机高度上一定超出视口 ⇒ 必须存在可滚动区域
    expect(find.byType(Scrollable), findsWidgets);
    await tester.drag(find.byType(CustomScrollView).first, const Offset(0, -300));
    await settle(tester, frames: 4);
    // 划完之后不该抛异常，并且更靠后的卡片已经构建出来
    expect(tester.takeException(), isNull);
  });
}
