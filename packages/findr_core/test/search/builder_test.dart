import 'package:findr_core/findr_core.dart';
import 'package:test/test.dart';

/// `search/builder.dart` 的验收网。
///
/// TS 侧没有对应的独立测试文件（`relaxations` 由 `search-relax.test.ts` 经 service 间接覆盖），
/// 这里直接打这一层：它是「模型输出 → SQL 条件」的翻译关口，
/// 译错了上层全都错，而它本身是纯函数、测起来便宜。
void main() {
  String? noCategories(String name) => null;

  group('词切分与转义', () {
    test('splitTerms 按 3 字分界（trigram 的物理下限）', () {
      final split = splitTerms(<String>['护照', '圆珠笔', '猫砂', '  ', '圆珠笔']);
      expect(split.fts, <String>['圆珠笔']);
      expect(split.like, <String>['护照', '猫砂']);
    });

    test('quoteFts 把词包成短语并转义内部引号', () {
      expect(quoteFts('圆珠笔'), '"圆珠笔"');
      expect(quoteFts('a"b'), '"a""b"');
    });

    test('escapeLike 转义 LIKE 的三个元字符', () {
      expect(escapeLike('100%'), r'100\%');
      expect(escapeLike('a_b'), r'a\_b');
      expect(escapeLike(r'c\d'), r'c\\d');
      expect(escapeLike('主卧'), '主卧');
    });
  });

  group('buildSearch', () {
    test('intent=unknown 或关键词为空时返回 null（不盲查）', () {
      expect(
        buildSearch(
          p2: const P2Output(intent: P2Intent.unknown, keywords: <String>['护照']),
          resolveCategoryId: noCategories,
        ),
        isNull,
      );
      expect(
        buildSearch(
          p2: const P2Output(intent: P2Intent.findItem, keywords: <String>[]),
          resolveCategoryId: noCategories,
        ),
        isNull,
      );
    });

    test('match_mode 决定短语之间是 OR 还是 AND', () {
      final any = buildSearch(
        p2: const P2Output(
          intent: P2Intent.findItem,
          keywords: <String>['圆珠笔', '笔记本'],
        ),
        resolveCategoryId: noCategories,
      );
      expect(any!.ftsExpr, '"圆珠笔" OR "笔记本"');
      expect(any.matchMode, MatchMode.any);

      final all = buildSearch(
        p2: const P2Output(
          intent: P2Intent.findItem,
          keywords: <String>['圆珠笔', '笔记本'],
          matchMode: MatchMode.all,
        ),
        resolveCategoryId: noCategories,
      );
      expect(all!.ftsExpr, '"圆珠笔" AND "笔记本"');
    });

    test('3 字以下的关键词只进 likeTerms，不进 FTS 表达式', () {
      final s = buildSearch(
        p2: const P2Output(intent: P2Intent.findItem, keywords: <String>['护照', '圆珠笔']),
        resolveCategoryId: noCategories,
      );
      expect(s!.ftsExpr, '"圆珠笔"');
      expect(s.likeTerms, <String>['护照']);
    });

    test('分类名交给 resolveCategoryId 解析（可能是模型回显的变体）', () {
      final s = buildSearch(
        p2: const P2Output(
          intent: P2Intent.findItem,
          keywords: <String>['圆珠笔'],
          category: '📍物品存取',
        ),
        resolveCategoryId: (name) => name.contains('物品存取') ? 'cat_item' : null,
      );
      expect(s!.categoryId, 'cat_item');
    });

    test('path_prefix 拼成转义后的 LIKE 前缀', () {
      final s = buildSearch(
        p2: const P2Output(
          intent: P2Intent.findItem,
          keywords: <String>['圆珠笔'],
          pathPrefix: <String>['主卧', '衣柜'],
        ),
        resolveCategoryId: noCategories,
      );
      expect(s!.pathPrefixLike, '主卧/衣柜%');
    });

    test('time_hint 换算成距今的绝对时刻（UTC 的 ISO 串）', () {
      final now = DateTime.parse('2026-03-01T00:00:00.000Z');
      final s = buildSearch(
        p2: const P2Output(
          intent: P2Intent.findItem,
          keywords: <String>['圆珠笔'],
          timeHint: TimeHint.recent,
        ),
        resolveCategoryId: noCategories,
        now: now,
      );
      expect(s!.sinceIso, '2026-02-26T00:00:00.000Z');

      // 没给 time_hint 就不加时间过滤
      final noHint = buildSearch(
        p2: const P2Output(intent: P2Intent.findItem, keywords: <String>['圆珠笔']),
        resolveCategoryId: noCategories,
        now: now,
      );
      expect(noHint!.sinceIso, isNull);
    });

    test('同义词与关键词一起参与切分', () {
      final s = buildSearch(
        p2: const P2Output(
          intent: P2Intent.findItem,
          keywords: <String>['圆珠笔'],
          synonyms: <String>['原子笔'],
        ),
        resolveCategoryId: noCategories,
      );
      expect(s!.ftsExpr, '"圆珠笔" OR "原子笔"');
    });
  });

  group('relaxations', () {
    const full = BuiltSearch(
      ftsExpr: '"护照"',
      likeTerms: <String>['证件'],
      matchMode: MatchMode.all,
      categoryId: 'cat_todo',
      pathPrefixLike: '主卧%',
      sinceIso: '2026-02-01T00:00:00.000Z',
      limit: 50,
    );

    test('放宽顺序：先去掉分类，再去掉路径/时间，最后 all→any', () {
      final steps = relaxations(full);
      expect(steps, hasLength(3));

      expect(steps[0].categoryId, isNull);
      expect(steps[0].pathPrefixLike, '主卧%', reason: '第一步只该动分类');
      expect(steps[0].matchMode, MatchMode.all);

      expect(steps[1].pathPrefixLike, isNull);
      expect(steps[1].sinceIso, isNull);
      expect(steps[1].matchMode, MatchMode.all, reason: '第二步还没到连接方式');

      expect(steps[2].matchMode, MatchMode.any);

      // 语义核心始终不动 —— 动了就变成「另一个查询」了
      for (final step in steps) {
        expect(step.ftsExpr, '"护照"');
        expect(step.likeTerms, <String>['证件']);
        expect(step.limit, 50);
      }
    });

    test('没有可放宽的条件时返回空（否则会重复查同一件事）', () {
      const minimal = BuiltSearch(
        ftsExpr: '"护照"',
        likeTerms: <String>[],
        matchMode: MatchMode.any,
        categoryId: null,
        pathPrefixLike: null,
        sinceIso: null,
        limit: 50,
      );
      expect(relaxations(minimal), isEmpty);
    });
  });

  group('buildRawSearch（离线兜底）', () {
    test('中文整句按虚词切开，落到实词上', () {
      // 「我的」「在哪」都是停用词；「护照」只剩 2 字 ⇒ 走 LIKE
      final short = buildRawSearch('我的护照在哪');
      expect(short.ftsExpr, isNull);
      expect(short.likeTerms, <String>['护照']);

      // 「手电筒」有 3 字 ⇒ 走 FTS
      final long = buildRawSearch('手电筒放在哪里');
      expect(long.ftsExpr, '"手电筒"');
      expect(long.likeTerms, isEmpty);
    });

    test('按标点切开后多个词走 OR，且恒为 any 模式', () {
      final s = buildRawSearch('圆珠笔，笔记本');
      expect(s.ftsExpr, '"圆珠笔" OR "笔记本"');
      expect(s.matchMode, MatchMode.any);
      expect(s.categoryId, isNull);
      expect(s.pathPrefixLike, isNull);
      expect(s.sinceIso, isNull);
    });

    test('整句都是虚词时退回原串（宁可 0 条也别查空条件）', () {
      final s = buildRawSearch('在哪');
      // 切空之后必须还有词，否则 SQL 里会剩一个恒真的空条件
      expect(s.ftsExpr != null || s.likeTerms.isNotEmpty, isTrue);
      expect(s.likeTerms, <String>['在哪']);
    });
  });
}
