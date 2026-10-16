import 'dart:convert';

import 'package:findr_core/findr_core.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// 推理题（advise）通道。
///
/// 一个典型的「无脑搜索」现场：库里有 护照 / 螺丝刀 / 插线板 / 剃须刀，
/// 问「我去国外玩应该会用到哪些东西」。期望返回 护照、剃须刀
/// （插线板视插座标准而定，应进 maybe 而不是被删掉或全留）。
///
/// 这个场景靠「更好的关键词」是解不掉的：P2_SYSTEM 明令「绝不假设库里存在什么物品」，
/// 所以「护照」这两个字永远不会进入关键词；而「旅游」与「护照」零字面重叠，
/// 本地 FTS/LIKE 也永远匹配不上。**缺的输入是库存本身，不是更好的关键词。**
///
/// 两处不在本文件：「P2 缺 mode 缺省为 locate」已由 `parse/parse_test.dart` 覆盖，
/// 三条「库存摘要」用例已由 `search/inventory_test.dart` 覆盖 —— 这里不重复。
final passport = makeCard(
  id: 'passport',
  entity: '护照',
  desc: '因私护照放在主卧床头柜第二层抽屉，和户口本放在一起。',
  pathNames: '主卧/床头柜',
  categoryId: 'cat_item',
);

final screwdriver = makeCard(
  id: 'screwdriver',
  entity: '螺丝刀',
  desc: '十字螺丝刀放在阳台工具柜最上层。',
  pathNames: '阳台/工具柜',
  categoryId: 'cat_item',
);

final powerstrip = makeCard(
  id: 'powerstrip',
  entity: '插线板',
  desc: '五孔插线板收在书房桌下的收纳箱里。',
  pathNames: '书房/桌前',
  categoryId: 'cat_item',
);

final shaver = makeCard(
  id: 'shaver',
  entity: '剃须刀',
  desc: '电动剃须刀放在卫生间镜柜里，充电线在旁边。',
  pathNames: '卫生间/镜柜',
  categoryId: 'cat_item',
);

void seedAdviseFixtures(SqliteDriver db) {
  for (final c in [passport, screwdriver, powerstrip, shaver]) {
    insertCard(db, c);
  }
}

const cfg = ProviderConfig(providerType: ProviderType.fake, model: 'fake');

final p2Advise = jsonEncode({
  'mode': 'advise',
  'intent': 'unknown',
  'keywords': <String>[],
  'synonyms': <String>[],
  'category': null,
  'path_prefix': null,
  'time_hint': null,
  'match_mode': 'any',
  'scenario': '出国旅游需要随身携带的物品',
  'aspects': ['证件', '洗漱用品', '电子产品'],
});

final p4Answer = jsonEncode({
  'picks': [
    {'id': 'passport', 'why': '出境必备'},
    {'id': 'shaver', 'why': '外出留宿要用'},
  ],
  'maybe': [
    {'id': 'powerstrip', 'why': '取决于目的地插座标准'},
  ],
  'missing': ['转换插头'],
  'answer': '出国你该带护照和剃须刀；插线板看目的地插座标准。库里还没有转换插头。',
});

void main() {
  group('adviseFromInventory 的三道防线', () {
    test('模型编造的 id 被丢弃，同一张卡不会同时出现在两档', () async {
      final db = makeDb();
      seedAdviseFixtures(db);
      final inv = buildInventory(db);
      final fake = FakeLlmAdapter([
        jsonEncode({
          'picks': [
            {'id': 'passport', 'why': '出境必备'},
            {'id': '不存在', 'why': '编的'},
          ],
          'maybe': [
            {'id': 'passport', 'why': '重复'},
            {'id': 'shaver', 'why': '看情况'},
          ],
          'missing': <String>[],
          'answer': 'ok',
        }),
      ]);

      final res = await adviseFromInventory(
        AdviceDeps(llm: fake, cfg: cfg),
        '出国带什么',
        '出国旅游',
        inv,
      );
      expect(res.ok, isTrue);
      expect(res.picks.map((p) => p.id).toList(), ['passport']);
      expect(res.maybe.map((m) => m.id).toList(), ['shaver']);
    });

    test('模型只回 id 字符串（不带 why）也能解析', () async {
      final db = makeDb();
      seedAdviseFixtures(db);
      final inv = buildInventory(db);
      final fake = FakeLlmAdapter([
        jsonEncode({
          'picks': ['passport'],
          'maybe': ['shaver'],
          'missing': <String>[],
          'answer': 'ok',
        }),
      ]);
      final res = await adviseFromInventory(
        AdviceDeps(llm: fake, cfg: cfg),
        '出国带什么',
        '出国旅游',
        inv,
      );
      expect(res.picks.map((p) => p.id).toList(), ['passport']);
      expect(res.picks.first.why, '');
    });

    test('missing 逐条去空白，空串不留', () async {
      final db = makeDb();
      seedAdviseFixtures(db);
      final inv = buildInventory(db);
      final fake = FakeLlmAdapter([
        jsonEncode({
          'picks': <String>[],
          'maybe': <String>[],
          'missing': ['  转换插头  ', '', '   '],
          'answer': 'ok',
        }),
      ]);
      final res = await adviseFromInventory(
        AdviceDeps(llm: fake, cfg: cfg),
        'q',
        's',
        inv,
      );
      expect(res.missing, ['转换插头']);
    });

    test('调用失败时 ok=false，由上层退到字面兜底', () async {
      final db = makeDb();
      seedAdviseFixtures(db);
      final inv = buildInventory(db);
      final res = await adviseFromInventory(
        AdviceDeps(llm: FakeLlmAdapter(), cfg: cfg),
        'q',
        's',
        inv,
      );
      expect(res.ok, isFalse);
      expect(res.error, isNotNull);
      expect(res.error, isNotEmpty);
    });

    test('模型回的不是 JSON 时同样 ok=false（不抛异常）', () async {
      final db = makeDb();
      seedAdviseFixtures(db);
      final inv = buildInventory(db);
      final res = await adviseFromInventory(
        AdviceDeps(llm: FakeLlmAdapter(['我不知道']), cfg: cfg),
        'q',
        's',
        inv,
      );
      expect(res.ok, isFalse);
      expect(res.error, isNotNull);
    });
  });

  group('端到端（走 searchCards）', () {
    test('出国玩该带什么 → 护照与剃须刀被挑出来，插线板进「看情况」', () async {
      final db = makeDb();
      seedAdviseFixtures(db);
      final fake = FakeLlmAdapter([p2Advise, p4Answer]);

      final res = await searchCards(
        SearchDeps(db: db, llm: fake, cfg: cfg),
        '我去国外玩应该会用到哪些东西',
      );

      expect(res.advice!.ok, isTrue);
      expect(res.cards.map((c) => c.id).toList(), [
        'passport',
        'shaver',
        'powerstrip',
      ]);
      expect(res.advice!.picks.map((p) => p.id).toList(), ['passport', 'shaver']);
      expect(res.advice!.maybe.map((m) => m.id).toList(), ['powerstrip']);
      expect(res.advice!.missing, ['转换插头']);
      expect(res.usedFallback, isFalse);
      // 走的是裁决通道，不是字面命中 —— 所以这些卡不该是 SQL 查出来的
      expect(res.relaxed, isNull);
    });

    test('裁决时模型真的看到了库存（缺的输入是库存，不是关键词）', () async {
      final db = makeDb();
      seedAdviseFixtures(db);
      final fake = FakeLlmAdapter([p2Advise, p4Answer]);
      await searchCards(
        SearchDeps(db: db, llm: fake, cfg: cfg),
        '我去国外玩应该会用到哪些东西',
      );

      expect(fake.requests, hasLength(2));
      final p4 = fake.requests[1].parts
          .map((p) => p is TextPart ? p.text : '')
          .join('');
      // 四张卡都在清单里 —— 螺丝刀也发了（模型必须有机会说它「不相关」）
      for (final name in ['护照', '螺丝刀', '插线板', '剃须刀']) {
        expect(p4, contains(name));
      }
      expect(p4, contains('出国旅游需要随身携带的物品'));
      // 模型必须被要求用常识判断，否则它只会做字面比较
      expect(fake.requests[1].system, contains('用常识判断'));
    });

    test('advise 模式下 keywords 为空也照走裁决（不能退化成「听不懂」）', () async {
      final db = makeDb();
      seedAdviseFixtures(db);
      final fake = FakeLlmAdapter([p2Advise, p4Answer]);

      final res = await searchCards(
        SearchDeps(db: db, llm: fake, cfg: cfg),
        '我去国外玩应该会用到哪些东西',
      );
      expect(fake.requests, hasLength(2));
      expect(res.unclear, isFalse);
      expect(res.advice, isNotNull);
    });

    test('空库不发第二次调用，直接说明还没有记忆', () async {
      final db = makeDb();
      final fake = FakeLlmAdapter([p2Advise]);

      final res = await searchCards(
        SearchDeps(db: db, llm: fake, cfg: cfg),
        '我去国外玩应该会用到哪些东西',
      );
      expect(fake.requests, hasLength(1));
      expect(res.cards, isEmpty);
      expect(res.advice!.answer, contains('还是空的'));
    });

    test('裁决失败退到字面兜底，并标记 usedFallback', () async {
      final db = makeDb();
      seedAdviseFixtures(db);
      // 只给 P2，P4 那一发直接抛错（模拟模型不可达）
      final fake = FakeLlmAdapter([p2Advise]);

      final res = await searchCards(
        SearchDeps(db: db, llm: fake, cfg: cfg),
        '我去国外玩应该会用到哪些东西',
      );
      expect(res.usedFallback, isTrue);
      expect(res.advice, isNull);
    });

    test('locate 模式不受影响，仍走字面检索', () async {
      final db = makeDb();
      insertCard(db, passport);
      final fake = FakeLlmAdapter([
        jsonEncode({
          'mode': 'locate',
          'intent': 'find_item',
          'keywords': ['护照'],
          'synonyms': <String>[],
          'category': null,
          'path_prefix': null,
          'time_hint': null,
          'match_mode': 'any',
          'scenario': null,
          'aspects': <String>[],
        }),
      ]);

      final res = await searchCards(
        SearchDeps(db: db, llm: fake, cfg: cfg),
        '我护照放哪了',
      );
      expect(res.cards.map((c) => c.id).toList(), ['passport']);
      expect(res.advice, isNull);
      expect(fake.requests, hasLength(1));
    });

    test('裁决一条都没挑中、但字面命中时，不让它变成静默空结果', () async {
      final db = makeDb();
      insertCard(db, passport);
      // 模拟「定位题被误判成推理题」：模型说库里没相关的，但字面其实查得到
      final fake = FakeLlmAdapter([
        p2Advise,
        jsonEncode({
          'picks': <String>[],
          'maybe': <String>[],
          'missing': <String>[],
          'answer': '库里没找到相关的。',
        }),
      ]);

      final res = await searchCards(
        SearchDeps(db: db, llm: fake, cfg: cfg),
        '护照在哪',
      );
      expect(res.cards.map((c) => c.id).toList(), ['passport']);
      // 这里的 usedFallback 是「模型没挑出来，下面是字面命中的」，
      // 不是「模型不可达」—— UI 必须按前者措辞
      expect(res.usedFallback, isTrue);
      expect(res.advice, isNotNull);
    });
  });
}
