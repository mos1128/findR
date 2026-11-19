/// 「已归档」这一页的验收网。
///
/// 归档的卡在记忆流与检索里都看不到（SQL 硬过滤），这一页是**唯一的出口** ——
/// 它一旦坏了，用户点过「归档」就等于把卡片丢进了黑洞。
library;

import 'dart:io';

import 'package:findr_app/platform/app_paths.dart';
import 'package:findr_app/platform/db.dart';
import 'package:findr_app/platform/secure.dart';
import 'package:findr_app/platform/runtime.dart';
import 'package:findr_app/screens/settings/archived_screen.dart';
import 'package:findr_app/theme/tokens.dart';
import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

late Directory _root;

Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> pumpArchived(WidgetTester tester) async {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester, frames: 2);
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiKeyStoreProvider.overrideWithValue(MemoryApiKeyStore())],
      child: MaterialApp(
        theme: buildFindrTheme(Brightness.light),
        home: const ArchivedScreen(),
      ),
    ),
  );
  await settle(tester);
}

/// 塞一张已归档的卡：先建草稿，再把状态改成 archived（界面上的「归档」也走这条）。
void seedArchived(String transcript) {
  final db = openAndMigrateDb();
  final id = makeId();
  createDraft(db, CaptureInput(source: SourceKind.text, text: transcript), id: id);
  setCardStatus(db, id, CardStatus.archived, DateTime.now());
  db.close();
}

void main() {
  setUp(() async {
    _root = await Directory.systemTemp.createTemp('findr_archived_');
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

  testWidgets('没有归档时给空态，并说清怎么归档', (tester) async {
    await pumpArchived(tester);

    expect(find.text('没有归档的卡片'), findsOneWidget);
    expect(find.text('在记忆流里长按一张卡片，选「归档」。'), findsOneWidget);
  });

  testWidgets('归档的卡在这里能看见；恢复后回到记忆流', (tester) async {
    seedArchived('护照放在主卧抽屉里');
    await pumpArchived(tester);

    expect(find.textContaining('护照放在主卧抽屉里'), findsOneWidget);
    // 归档的卡默认不在记忆流里，这里是唯一能看见它的地方
    expect(find.text('1 张'), findsOneWidget);

    await tester.tap(find.byTooltip('恢复到记忆流'));
    await settle(tester);

    final db = openAndMigrateDb();
    final cards = listCards(db);
    db.close();
    expect(cards, hasLength(1), reason: '恢复 = 回到 active，重新出现在记忆流里');
    expect(cards.first.status, CardStatus.active);

    expect(find.text('没有归档的卡片'), findsOneWidget, reason: '恢复后这一页就空了');
  });

  testWidgets('彻底删除：弹窗写明附件一起去，确认后库里没了', (tester) async {
    seedArchived('要删掉的旧笔记');
    await pumpArchived(tester);

    await tester.tap(find.byTooltip('彻底删除'));
    await settle(tester);
    expect(find.text('图片和录音会一起删掉，不可恢复。'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await settle(tester);

    final db = openAndMigrateDb();
    expect(listCards(db, const ListCardsOptions(includeArchived: true)), isEmpty);
    db.close();
    expect(find.text('没有归档的卡片'), findsOneWidget);
  });
}
