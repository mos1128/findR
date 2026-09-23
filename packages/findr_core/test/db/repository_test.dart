import 'package:findr_core/findr_core.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  // ─────────────────────────────────────────────────────────
  // 分类与位置树
  // ─────────────────────────────────────────────────────────
  group('分类与位置树的解析', () {
    test('分类名匹配容忍 emoji / 空白 / 标点变体（模型回显）', () {
      final db = makeDb();
      expect(resolveCategoryId(db, '物品存取'), 'cat_item');
      expect(resolveCategoryId(db, '📍物品存取'), 'cat_item');
      expect(resolveCategoryId(db, ' 物品存取 '), 'cat_item');
      expect(resolveCategoryId(db, '物品存取（item）'), 'cat_item');
      expect(resolveCategoryId(db, '不存在的分类'), isNull);
    });

    test('位置树逐级匹配，任一级失配返回 null', () {
      final db = makeDb();
      upsertLocation(db, const LocationNode(id: 'loc_1', parentId: null, name: '主卧', sort: 0));
      upsertLocation(
        db,
        const LocationNode(id: 'loc_2', parentId: 'loc_1', name: '衣柜', sort: 0),
      );
      final hit = resolvePath(db, <String>['主卧', '衣柜']);
      expect(hit?.ids, <String>['loc_1', 'loc_2']);
      expect(hit?.namesStr, '主卧/衣柜');
      expect(resolvePath(db, <String>['主卧', '书桌']), isNull);
      expect(resolvePath(db, <String>['书房']), isNull);
    });

    test('ensurePath：缺失层级直接新建、已有层级复用', () {
      final db = makeDb();
      var n = 0;
      String idGen() => 'loc_${++n}';

      final first = ensurePath(db, <String>['主卧', '衣柜'], idGen: idGen);
      expect(first.created, <String>['主卧', '衣柜']);
      expect(first.namesStr, '主卧/衣柜');

      // 第二次完全命中，不该再建节点
      final again = ensurePath(db, <String>['主卧', '衣柜'], idGen: idGen);
      expect(again.created, isEmpty);
      expect(again.ids, first.ids);

      // 只补缺失的最后一层
      final deeper = ensurePath(db, <String>['主卧', '衣柜', '顶层'], idGen: idGen);
      expect(deeper.created, <String>['顶层']);
      expect(deeper.ids.sublist(0, 2), first.ids);
    });

    test('ensurePath：同名但父不同不会串到一条链上', () {
      final db = makeDb();
      var n = 0;
      String idGen() => 'loc_${++n}';

      final a = ensurePath(db, <String>['主卧', '衣柜'], idGen: idGen);
      final b = ensurePath(db, <String>['次卧', '衣柜'], idGen: idGen);
      expect(b.created, <String>['次卧', '衣柜']);
      expect(b.ids[1], isNot(a.ids[1]));
      final names = listLocations(db).map((l) => l.name).toList()..sort();
      expect(names, <String>['主卧', '次卧', '衣柜', '衣柜']);
    });

    test('ensurePath：命中位置别名时复用已有节点', () {
      final db = makeDb();
      var n = 0;
      String idGen() => 'loc_${++n}';

      final first = ensurePath(db, <String>['主卧'], idGen: idGen);
      db
          .prepare(
            "INSERT INTO aliases (id, kind, name, location_id) VALUES (?, 'location', ?, ?)",
          )
          .run(<Object?>[idGen(), '睡房', first.ids[0]]);

      // 「睡房」是「主卧」的别名 ⇒ 复用，而不是又建一个平行的房间
      final viaAlias = ensurePath(db, <String>['睡房'], idGen: idGen);
      expect(viaAlias.created, isEmpty);
      expect(viaAlias.ids, first.ids);
    });
  });

  // ─────────────────────────────────────────────────────────
  // 卡片读写
  // ─────────────────────────────────────────────────────────
  group('记忆流读取与编辑', () {
    test('listCards 默认排除归档，但草稿两态恒定可见', () {
      final db = makeDb();
      insertCard(db, makeCard(id: 'c_active'));
      insertCard(db, makeCard(id: 'c_pending', status: CardStatus.pending));
      insertCard(db, makeCard(id: 'c_ptr', status: CardStatus.pendingTranscript));
      insertCard(db, makeCard(id: 'c_archived', status: CardStatus.archived));

      final ids = listCards(db).map((c) => c.id).toList();
      expect(ids, contains('c_active'));
      expect(ids, contains('c_pending'));
      expect(ids, contains('c_ptr'));
      expect(ids, isNot(contains('c_archived')));
      expect(countCards(db), 3);

      final withArchived = listCards(
        db,
        const ListCardsOptions(includeArchived: true),
      ).map((c) => c.id);
      expect(withArchived, contains('c_archived'));
    });

    test('listCards 支持单类筛选与分页', () {
      final db = makeDb();
      for (var i = 0; i < 5; i++) {
        insertCard(
          db,
          makeCard(
            id: 'c$i',
            categoryId: i < 2 ? 'cat_todo' : 'cat_item',
            createdAt: '2026-03-0${i + 1}T00:00:00.000Z',
          ),
        );
      }
      expect(
        listCards(db, const ListCardsOptions(categoryId: 'cat_todo')).map((c) => c.id),
        <String>['c1', 'c0'],
      );
      expect(countCards(db, const ListCardsOptions(categoryId: 'cat_item')), 3);
      final page = listCards(db, const ListCardsOptions(limit: 2, offset: 2));
      expect(page, hasLength(2));
    });

    test('updateCardFields 只写传入的键，JSON 列序列化，恒定刷新 updated_at', () {
      final db = makeDb();
      insertCard(db, makeCard(id: 'c1', entity: '旧名', tags: <String>['a']));

      updateCardFields(
        db,
        'c1',
        const CardPatch(
          entity: '新名',
          tags: <String>['x', 'y'],
          steps: <StepItem>[StepItem(text: '第一步', done: true)],
        ),
        testNow,
      );
      final card = getCard(db, 'c1')!;
      expect(card.entity, '新名');
      expect(card.tags, <String>['x', 'y']);
      expect(card.steps, <StepItem>[const StepItem(text: '第一步', done: true)]);
      expect(card.updatedAt, isoUtc(testNow));
      // 未传入的字段保持不动
      expect(card.status, CardStatus.active);
      expect(card.categoryId, 'cat_item');

      // 显式传 null 才会清空
      updateCardFields(db, 'c1', const CardPatch(tags: null), testNow);
      expect(getCard(db, 'c1')!.tags, isNull);
    });

    test('卡片只保留分类这一个组织维度（结构类型与业务状态已从产品移除）', () {
      final db = makeDb();
      insertCard(db, makeCard(id: 'c1', categoryId: 'cat_todo'));
      updateCardFields(db, 'c1', const CardPatch(categoryId: 'cat_procedure'), testNow);
      expect(getCard(db, 'c1')!.categoryId, 'cat_procedure');
      // 物理列也必须真的不存在了，否则备份/检索会读到幽灵数据
      final cols = columnsOf(db, 'cards');
      for (final gone in <String>[
        'structure_type',
        'item_status',
        'todo_status',
        'procedure_status',
        'related_person',
        'due_at',
        'cycle',
      ]) {
        expect(cols, isNot(contains(gone)), reason: 'cards 仍残留列 $gone');
      }
    });

    test('待整理标志的清除动作', () {
      final db = makeDb();
      insertCard(db, makeCard(id: 'c1', needsOrganize: true));
      clearNeedsOrganize(db, 'c1', testNow);
      expect(getCard(db, 'c1')!.needsOrganize, isFalse);
    });

    test('vision_analyzed 三态可写', () {
      final db = makeDb();
      insertCard(db, makeCard(id: 'c1', visionAnalyzed: false, images: <String>['files/a.webp']));
      setVisionAnalyzed(db, 'c1', true, testNow);
      expect(getCard(db, 'c1')!.visionAnalyzed, isTrue);
      // 没图时恒为 null（「分析过」这件事对纯文本卡没有意义）
      insertCard(db, makeCard(id: 'c2'));
      expect(getCard(db, 'c2')!.visionAnalyzed, isNull);
    });

    test('归档与恢复', () {
      final db = makeDb();
      insertCard(db, makeCard(id: 'c1'));
      setCardStatus(db, 'c1', CardStatus.archived, testNow);
      expect(listCards(db).map((c) => c.id), isNot(contains('c1')));
      setCardStatus(db, 'c1', CardStatus.active, testNow);
      expect(listCards(db).map((c) => c.id), contains('c1'));
    });

    test('setTranscript 把待转写推进到待解析并清掉补问', () {
      final db = makeDb();
      insertCard(
        db,
        makeCard(id: 'c1', status: CardStatus.pendingTranscript, ask: '这是哪个房间？'),
      );
      setTranscript(db, 'c1', '手电筒放主卧衣柜', testNow);
      final card = getCard(db, 'c1')!;
      expect(card.transcript, '手电筒放主卧衣柜');
      expect(card.status, CardStatus.pending);
      expect(card.ask, isNull);
    });

    test('setTranscript 不会把已入库的卡片退回待解析', () {
      final db = makeDb();
      insertCard(db, makeCard(id: 'c1', transcript: '旧文本'));
      setTranscript(db, 'c1', '新文本', testNow);
      expect(getCard(db, 'c1')!.status, CardStatus.active);
    });

    test('deleteCard 连带清掉别名', () {
      final db = makeDb();
      insertCard(db, makeCard(id: 'c1'));
      db
          .prepare("INSERT INTO aliases (id, kind, name, card_id) VALUES (?, 'entity', ?, ?)")
          .run(<Object?>['al1', '手电', 'c1']);
      deleteCard(db, 'c1');
      expect(getCard(db, 'c1'), isNull);
      expect(db.prepare('SELECT COUNT(*) AS n FROM aliases').get()?['n'], 0);
    });

    test('upsertCard 整行覆盖（备份导入用，含编辑白名单外的列）', () {
      final db = makeDb();
      insertCard(db, makeCard(id: 'c1', entity: '旧实体'));
      upsertCard(
        db,
        makeCard(
          id: 'c1',
          entity: '新实体',
          status: CardStatus.archived,
          retryCount: 3,
          lastError: '上次失败原因',
        ),
      );
      final card = getCard(db, 'c1')!;
      expect(card.entity, '新实体');
      expect(card.status, CardStatus.archived);
      expect(card.retryCount, 3);
      expect(card.lastError, '上次失败原因');
    });

    test('队列遵守退避时间与自动重试上限', () {
      final db = makeDb();
      insertCard(db, makeCard(id: 'ready', status: CardStatus.pending));
      insertCard(
        db,
        makeCard(
          id: 'backoff',
          status: CardStatus.pending,
          nextRetryAt: '2026-03-02T00:00:00.000Z',
        ),
      );
      insertCard(db, makeCard(id: 'exhausted', status: CardStatus.pending, retryCount: maxAutoRetry));
      insertCard(db, makeCard(id: 'done', status: CardStatus.active));

      expect(listQueueCards(db, testNow).map((c) => c.id), <String>['ready']);
    });

    test('resetTranscriptRetries 无视退避与上限（批量补转写）', () {
      final db = makeDb();
      insertCard(
        db,
        makeCard(
          id: 'p1',
          status: CardStatus.pendingTranscript,
          retryCount: maxAutoRetry,
          nextRetryAt: '2026-04-01T00:00:00.000Z',
          lastError: '网络失败',
        ),
      );
      insertCard(db, makeCard(id: 'p2', status: CardStatus.pending));

      expect(resetTranscriptRetries(db, testNow), 1);
      // p1 此前已耗尽重试且未到退避时间，重置后重新可被队列捞起
      final queued = listQueueCards(db, testNow).map((c) => c.id).toList();
      expect(queued, contains('p1'));
      expect(queued, contains('p2'));
      expect(getCard(db, 'p1')!.lastError, isNull);
      expect(getCard(db, 'p1')!.retryCount, 0);
      expect(getCard(db, 'p1')!.nextRetryAt, isNull);
    });
  });

  group('重试退避', () {
    test('退避序列是 1min→5min→30min→2h→次日，共 5 档', () {
      expect(retryBackoffMs, <int>[60000, 300000, 1800000, 7200000, 86400000]);
      expect(maxAutoRetry, 5);
    });

    test('computeBackoffMs 把次数夹在 1..maxAutoRetry', () {
      expect(computeBackoffMs(0), 60000);
      expect(computeBackoffMs(1), 60000);
      expect(computeBackoffMs(2), 300000);
      expect(computeBackoffMs(5), 86400000);
      expect(computeBackoffMs(99), 86400000);
    });

    test('markRetry 自增次数并按退避排期', () {
      final db = makeDb();
      insertCard(db, makeCard(id: 'c1', status: CardStatus.pending));

      markRetry(db, 'c1', '第一次失败', testNow);
      final first = getCard(db, 'c1')!;
      expect(first.retryCount, 1);
      expect(first.lastError, '第一次失败');
      expect(first.nextRetryAt, isoUtc(testNow.add(const Duration(minutes: 1))));
      expect(first.updatedAt, isoUtc(testNow));

      // 第二次失败落在第二档（5min），是以「本次失败时刻」为基准算的
      final later = testNow.add(const Duration(minutes: 10));
      markRetry(db, 'c1', '第二次失败', later);
      final second = getCard(db, 'c1')!;
      expect(second.retryCount, 2);
      expect(second.nextRetryAt, isoUtc(later.add(const Duration(minutes: 5))));
    });
  });

  // ─────────────────────────────────────────────────────────
  // 检索 SQL 的集成验证 —— 直接打 executeSearch，
  // 它是「SQL 拼得对不对」的第一道关口
  // ─────────────────────────────────────────────────────────
  group('executeSearch', () {
    test('≥3 字词走 FTS trigram，中文能命中', () {
      final db = makeDb();
      insertCard(db, makeCard(id: 'c1', desc: '蓝色的圆珠笔放在书桌抽屉里'));
      insertCard(db, makeCard(id: 'c2', desc: '红色笔记本'));

      final hits = executeSearch(db, buildRawSearch('圆珠笔'));
      expect(hits.map((c) => c.id), <String>['c1']);
    });

    test('短词降级 LIKE（trigram 的物理下限）', () {
      final db = makeDb();
      insertCard(db, makeCard(id: 'c1', desc: '护照放在主卧抽屉'));
      insertCard(db, makeCard(id: 'c2', desc: '笔记本'));

      // 「护照」只有 2 字，FTS 匹配不到，必须走 LIKE 才可能有结果
      final search = buildRawSearch('护照');
      expect(search.ftsExpr, isNull);
      expect(search.likeTerms, <String>['护照']);

      final hits = executeSearch(db, search);
      expect(hits.map((c) => c.id), <String>['c1']);
    });

    test('恒定过滤归档卡与草稿卡', () {
      final db = makeDb();
      insertCard(db, makeCard(id: 'c_active', desc: '圆珠笔在这里'));
      insertCard(db, makeCard(id: 'c_archived', status: CardStatus.archived, desc: '圆珠笔在这里'));
      insertCard(db, makeCard(id: 'c_pending', status: CardStatus.pending, desc: '圆珠笔在这里'));

      final hits = executeSearch(db, buildRawSearch('圆珠笔'));
      expect(hits.map((c) => c.id), <String>['c_active']);
    });

    test('分类与时间过滤生效，放宽后能把结果找回来', () {
      final db = makeDb();
      insertCard(
        db,
        makeCard(id: 'c1', categoryId: 'cat_item', desc: '圆珠笔在这里'),
      );

      // 模型把分类猜成「待买补货」时，严格条件会整批剔掉正确答案
      final strict = buildRawSearch('圆珠笔').copyWith(categoryId: 'cat_todo');
      expect(executeSearch(db, strict), isEmpty);

      // 放宽第一级（去掉分类）就该找回
      final relaxed = relaxations(strict).first;
      expect(relaxed.categoryId, isNull);
      expect(executeSearch(db, relaxed).map((c) => c.id), <String>['c1']);
    });
  });
}
