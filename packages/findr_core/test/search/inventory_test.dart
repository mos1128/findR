import 'package:findr_core/findr_core.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// 库存清单的**排序**（6 个用例），加上库存摘要那三条。
///
/// 起因：用户问「物品加得很多以后，岂不是一次性把一大堆物品的信息传给大模型」。
/// 定位题不受影响（它只发命中片段），但推理题的清单确实随库增长 ——
/// 而真正的毛病不是 token 上界，是**排序依据**：
/// 走 `listCards`（`ORDER BY created_at DESC`）等于把「最近的 200 条」当成
/// 「最相关的 200 条」。库一大，清单就被无关的新卡占满，
/// **去年记的护照正好被截在 200 之外** —— 那恰恰是这条链路存在的唯一理由。
void main() {
  final passport = makeCard(
    id: 'passport',
    entity: '护照',
    desc: '因私护照放在主卧床头柜第二层抽屉，和户口本放在一起。',
    tags: const ['证件', '出行'],
    pathNames: '主卧/床头柜',
    categoryId: 'cat_item',
    createdAt: '2025-01-01T00:00:00.000Z',
  );

  /// 严格递增的时间戳：让「时间倒序」这件事在测试里是确定的。
  ///
  /// 造一条逐分钟递增的时间戳 ——
  /// 月份 0-based（5 = 六月），且**分秒超出范围会自动进位**（两边都一样）。
  String at(int index) => isoUtc(DateTime.utc(2026, 6, 1, 0, index));

  /// 一批与「出国玩该带什么」毫无关系的卡，且都比护照新。
  void seedNoise(SqliteDriver db, int count) {
    for (var i = 0; i < count; i++) {
      insertCard(
        db,
        makeCard(
          id: 'noise-${i.toString().padLeft(3, '0')}',
          entity: '杂物$i',
          createdAt: at(i),
        ),
      );
    }
  }

  const adviseTerms = <String?>[
    '证件',
    '洗漱用品',
    '电子产品',
    '出国旅游需要随身携带的物品',
    '我去国外玩应该会用到哪些东西',
  ];

  group('排序', () {
    test('库大了以后，最相关的旧卡不会被无关的新卡挤出清单', () {
      final db = makeDb();
      insertCard(db, passport);
      seedNoise(db, 260);

      // 改动前：这里拿到的是「最近 200 条」= noise-060 ~ noise-259，护照被截掉
      final inv = buildInventory(db, terms: adviseTerms);

      expect(inv.total, 261);
      expect(inv.listed, 200);
      expect(inv.truncated, isTrue);
      expect(inv.cards.any((c) => c.id == 'passport'), isTrue);
      // 命中了标签「证件」，相关度最高 ⇒ 排在第一条（模型最先读到）
      expect(inv.cards.first.id, 'passport');
    });

    test('命中主字段的排在「只在描述里提一句」的前面', () {
      final db = makeDb();
      insertCard(
        db,
        makeCard(
          id: 'by-entity',
          entity: '出国证件收纳袋',
          tags: const ['证件'],
          createdAt: '2025-01-01T00:00:00.000Z',
        ),
      );
      insertCard(
        db,
        makeCard(
          id: 'by-desc',
          entity: '鞋盒',
          desc: '鞋盒里塞着一些旧证件复印件和过期的名片。',
          createdAt: '2026-06-01T00:00:00.000Z',
        ),
      );

      final inv = buildInventory(db, terms: const ['证件'], limit: 1);
      expect(inv.cards.map((c) => c.id).toList(), ['by-entity']);
    });

    test('不传 terms 时保持原行为（按时间倒序，新的在前）', () {
      final db = makeDb();
      insertCard(db, makeCard(id: 'old', entity: '旧', createdAt: at(0)));
      insertCard(db, makeCard(id: 'new', entity: '新', createdAt: at(5)));

      final inv = buildInventory(db);
      expect(inv.cards.map((c) => c.id).toList(), ['new', 'old']);
      expect(inv.text, isNot(contains('最相关')));
    });

    test('提示词一个词都没碰上时，退回按时间倒序（不会比原来更差）', () {
      final db = makeDb();
      insertCard(db, makeCard(id: 'old', entity: '旧', createdAt: at(0)));
      insertCard(db, makeCard(id: 'new', entity: '新', createdAt: at(5)));

      final inv = buildInventory(db, terms: const ['zzz-完全不相干的词汇-qqq']);
      expect(inv.cards.map((c) => c.id).toList(), ['new', 'old']);
    });

    test('截断说明写的是「最相关」而不是「最近」', () {
      final db = makeDb();
      insertCard(db, passport);
      seedNoise(db, 10);

      final ranked = buildInventory(db, terms: const ['证件'], limit: 5);
      expect(ranked.text, contains('全库共 11 条'));
      expect(ranked.text, contains('与本次问题最相关的 5 条'));
      expect(ranked.text, contains('可能不全'));

      final plain = buildInventory(db, limit: 5);
      expect(plain.text, contains('最近的 5 条'));
    });

    test('提示词拆分：短词原样用，长句切成 2 字滑窗', () {
      final terms = relevanceTerms(['洗漱用品', '出国旅游需要带什么', null, '  ']);
      expect(terms, contains('洗漱用品'));
      expect(terms, contains('旅游'));
      expect(terms, contains('出国'));
      // 空值与纯空白不该混进词表
      expect(terms, isNot(contains('')));
    });
  });

  group('库存摘要', () {
    /// 与 `advise_test.dart` 的 `seed()` 同源：库里有 护照 / 螺丝刀 / 插线板 / 剃须刀。
    void seed(SqliteDriver db) {
      for (final c in [
        passport,
        makeCard(
          id: 'screwdriver',
          entity: '螺丝刀',
          desc: '十字螺丝刀放在阳台工具柜最上层。',
          pathNames: '阳台/工具柜',
          categoryId: 'cat_item',
        ),
        makeCard(
          id: 'powerstrip',
          entity: '插线板',
          desc: '五孔插线板收在书房桌下的收纳箱里。',
          pathNames: '书房/桌前',
          categoryId: 'cat_item',
        ),
        makeCard(
          id: 'shaver',
          entity: '剃须刀',
          desc: '电动剃须刀放在卫生间镜柜里，充电线在旁边。',
          pathNames: '卫生间/镜柜',
          categoryId: 'cat_item',
        ),
      ]) {
        insertCard(db, c);
      }
    }

    test('一条一行，含 id / 实体 / 分类 / 位置 / 简述', () {
      final db = makeDb();
      seed(db);
      final inv = buildInventory(db);

      expect(inv.total, 4);
      expect(inv.listed, 4);
      expect(inv.truncated, isFalse);
      expect(inv.text, contains('序号 | id | 实体 | 分类 | 位置 | 简述'));
      expect(inv.text, contains('| passport | 护照 |'));
      expect(inv.text, contains('主卧/床头柜'));
      expect(inv.text, contains('| shaver | 剃须刀 |'));
    });

    test('archived 不进清单（与记忆流一致）', () {
      final db = makeDb();
      insertCard(db, makeCard(id: 'gone', entity: '旧物', status: CardStatus.archived));
      insertCard(db, passport);
      final inv = buildInventory(db);
      expect(inv.total, 1);
      expect(inv.text, isNot(contains('旧物')));
    });

    test('超出上界时写明截断，而不是静默变少', () {
      final db = makeDb();
      for (var i = 0; i < 5; i++) {
        insertCard(db, makeCard(id: 'c$i', entity: '物件$i'));
      }
      final inv = buildInventory(db, limit: 2);
      expect(inv.total, 5);
      expect(inv.listed, 2);
      expect(inv.truncated, isTrue);
      expect(inv.text, contains('全库共 5 条'));
      expect(inv.text, contains('可能不全'));
    });

    test('空库给明确占位，而不是空白', () {
      final inv = buildInventory(makeDb());
      expect(inv.total, 0);
      expect(inv.listed, 0);
      expect(inv.truncated, isFalse);
      expect(inv.text, '（记忆库还是空的）');
    });

    test('limit = 0 时不列任何条目（上界可以压到零）', () {
      final db = makeDb();
      seed(db);
      final inv = buildInventory(db, limit: 0);
      expect(inv.listed, 0);
      expect(inv.cards, isEmpty);
      expect(inv.truncated, isTrue);
    });
  });
}
