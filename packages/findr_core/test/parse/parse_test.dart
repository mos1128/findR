import 'package:findr_core/findr_core.dart';
import 'package:test/test.dart';

/// `parse/` 的验收网 —— 对应 `packages/core/test/parse.test.ts`（7 个用例），
/// 另加一组 TS 那边没明写、但**行为上必须一致**的用例：
/// **哪些字段的失败会让整次解析作废**（zod 的 `.catch()` 边界，见 `parse/schema.dart` 文件头）。
///
/// 这一层值得多押几分：它是「模型输出 → 我们的数据结构」的唯一关口，
/// 而模型的 JSON 永远不守规矩。
///
/// 与 TS 的 `const Simple = z.object({ a: z.number() })` 同源：
/// 只认 `{a: number}` 的最小校验器，用来单独验「抽取 + 修复」这两步。
num? _simpleSchema(Object? json) {
  if (json is Map && json['a'] is num) return json['a'] as num;
  return null;
}

void main() {
  group('抽取与修复', () {
    test('提取 markdown 围栏中的 JSON', () {
      final r = parseModelJson('```json\n{"a":1}\n```', _simpleSchema);
      expect(r, isA<ParseOk<num>>());
      expect((r as ParseOk<num>).value, 1);
    });

    test('提取被解释文字包围的 JSON', () {
      final r = parseModelJson('好的，结果如下：{"a": 2} 以上。', _simpleSchema);
      expect(r, isA<ParseOk<num>>());
      expect((r as ParseOk<num>).value, 2);
    });

    test('修复尾逗号', () {
      final r = parseModelJson('{"a": 1,}', _simpleSchema);
      expect(r, isA<ParseOk<num>>());
      expect((r as ParseOk<num>).value, 1);
    });

    test('没有 JSON 时失败且不抛异常', () {
      final r = parseModelJson<num>('抱歉，我不知道你在说什么', _simpleSchema);
      expect(r, isA<ParseFailure<num>>());
      expect((r as ParseFailure<num>).error, isNotEmpty);
    });

    test('extractJson：取首个 { 到末个 }（不是配平括号）', () {
      expect(extractJson('前置 {"a": 1} 后置'), '{"a": 1}');
      expect(extractJson('没有大括号'), isNull);
      expect(extractJson('只有一个 {'), isNull);
      // 末个 `}` 在 `{` 之前 ⇒ 也算没有
      expect(extractJson('} {"a": 1'), isNull);
    });

    test('fixJson：吃尾逗号，不动正常内容', () {
      expect(fixJson('{"a": 1,}'), '{"a": 1}');
      // `,\s*` 会把逗号与它后面的空白**一起吃掉**再换成 `}`/`]` —— 与 TS 的正则同行为
      expect(fixJson('[1, 2, ]'), '[1, 2]');
      expect(fixJson('{"a": 1}'), '{"a": 1}');
    });
  });

  group('P1 schema', () {
    test('字段缺失走宽松缺省', () {
      final r = parseModelJson(
        '{"category":"物品存取","entity":"护照"}',
        P1OutputSchema.tryParse,
      );
      expect(r, isA<ParseOk<P1Output>>());
      final v = (r as ParseOk<P1Output>).value;
      expect(v.entity, '护照');
      expect(v.category, '物品存取');
      expect(v.desc, '');
      expect(v.steps, isEmpty);
      expect(v.aliases, isEmpty);
      expect(v.path, isNull);
      expect(v.confidence, isNull);
    });

    test('模型多吐已废弃字段不影响解析（老提示词 / 缓存样本仍可用）', () {
      final r = parseModelJson(
        '{"structure_type":"item","item_status":"in_stock","related_person":"老王","entity":"梯子"}',
        P1OutputSchema.tryParse,
      );
      expect(r, isA<ParseOk<P1Output>>());
      expect((r as ParseOk<P1Output>).value.entity, '梯子');
    });

    test('model 完全没给 JSON 才失败（触发待整理路径）', () {
      final r = parseModelJson<P1Output>('我不知道该怎么整理这条', P1OutputSchema.tryParse);
      expect(r, isA<ParseFailure<P1Output>>());
    });

    test('confidence 越界算失败 ⇒ 落 null（zod 的 .min(0).max(1)）', () {
      final ok = parseModelJson('{"entity":"x","confidence":0.86}', P1OutputSchema.tryParse);
      expect((ok as ParseOk<P1Output>).value.confidence, 0.86);

      final tooBig = parseModelJson<P1Output>(
        '{"entity":"x","confidence":1.5}',
        P1OutputSchema.tryParse,
      );
      expect(tooBig, isA<ParseOk<P1Output>>());
      expect((tooBig as ParseOk<P1Output>).value.confidence, isNull);
    });

    test('没有 .catch 的字段类型不对 ⇒ 整次解析作废（path_matched）', () {
      final r = parseModelJson<P1Output>(
        '{"entity":"x","path_matched":"yes"}',
        P1OutputSchema.tryParse,
      );
      expect(r, isA<ParseFailure<P1Output>>());
    });
  });

  group('P2 schema', () {
    test('陌生 mode / 缺 intent 都落默认（老模型行为不会更差）', () {
      final r = parseModelJson(
        '{"mode":"搜一下","intent":"find_item","keywords":["护照"]}',
        P2OutputSchema.tryParse,
      );
      expect(r, isA<ParseOk<P2Output>>());
      final v = (r as ParseOk<P2Output>).value;
      expect(v.mode, SearchMode.locate);
      expect(v.intent, P2Intent.findItem);
      expect(v.keywords, ['护照']);
      // 没给的字段全落默认
      expect(v.synonyms, isEmpty);
      expect(v.matchMode, MatchMode.any);
      expect(v.aspects, isEmpty);
    });

    test('完全缺 mode 时是 locate，不是 advise', () {
      final r = parseModelJson('{"intent":"find_item","keywords":["护照"]}', P2OutputSchema.tryParse);
      final v = (r as ParseOk<P2Output>).value;
      expect(v.mode, SearchMode.locate);
      expect(v.aspects, isEmpty);
    });

    test('数组里混进非字符串 ⇒ 整档落空数组（zod 的 .catch 挂在数组上）', () {
      final r = parseModelJson(
        '{"keywords":["护照",123],"path_prefix":["主卧",7]}',
        P2OutputSchema.tryParse,
      );
      final v = (r as ParseOk<P2Output>).value;
      expect(v.keywords, isEmpty);
      // path_prefix 是 nullable().catch(null)：数组内部不合规 ⇒ 整档 null
      expect(v.pathPrefix, isNull);
    });

    test('time_hint 只能是我们认识的四个值，否则整次解析作废', () {
      final ok = parseModelJson('{"time_hint":"this_year"}', P2OutputSchema.tryParse);
      expect((ok as ParseOk<P2Output>).value.timeHint, TimeHint.thisYear);

      final bad = parseModelJson<P2Output>('{"time_hint":"yesterday"}', P2OutputSchema.tryParse);
      expect(bad, isA<ParseFailure<P2Output>>());
    });

    test('scenario / normalized_query 类型不对同样拖垮整次解析（它们没有 catch）', () {
      expect(
        parseModelJson<P2Output>('{"scenario":123}', P2OutputSchema.tryParse),
        isA<ParseFailure<P2Output>>(),
      );
      expect(
        parseModelJson<P2Output>('{"normalized_query":[]}', P2OutputSchema.tryParse),
        isA<ParseFailure<P2Output>>(),
      );
    });

    test('withSynonyms 只换同义词，其余字段原样', () {
      final base = parseModelJson(
        '{"mode":"advise","intent":"unknown","keywords":["a"],"synonyms":["x"],'
        '"category":"物品存取","time_hint":"recent","match_mode":"all",'
        '"scenario":"出国","aspects":["证件"],"normalized_query":"q"}',
        P2OutputSchema.tryParse,
      );
      final v = (base as ParseOk<P2Output>).value;
      final swapped = v.withSynonyms(['x', 'y']);
      expect(swapped.synonyms, ['x', 'y']);
      expect(swapped.mode, v.mode);
      expect(swapped.intent, v.intent);
      expect(swapped.keywords, v.keywords);
      expect(swapped.category, v.category);
      expect(swapped.timeHint, v.timeHint);
      expect(swapped.matchMode, v.matchMode);
      expect(swapped.scenario, v.scenario);
      expect(swapped.aspects, v.aspects);
      expect(swapped.normalizedQuery, v.normalizedQuery);
    });
  });

  group('P3 / P4 schema', () {
    test('P3 四个字段全缺也不失败（都有 catch）', () {
      final r = parseModelJson('{}', P3OutputSchema.tryParse);
      expect(r, isA<ParseOk<P3Output>>());
      final v = (r as ParseOk<P3Output>).value;
      expect(v.answer, '');
      expect(v.hitIds, isEmpty);
      expect(v.suggest, '');
    });

    test('P3 的 hit_ids 混进非字符串 ⇒ 整档落空（不指向不存在的卡）', () {
      final r = parseModelJson('{"hit_ids":["c1",9]}', P3OutputSchema.tryParse);
      expect((r as ParseOk<P3Output>).value.hitIds, isEmpty);
    });

    test('P4 的裁决条目两种写法都收：只回 id 字符串、或回 {id, why}', () {
      final r = parseModelJson(
        '{"picks":["passport",{"id":"shaver","why":"外出留宿要用"}],'
        '"maybe":[{"id":"powerstrip"}],"missing":["转换插头"],"answer":"ok"}',
        P4OutputSchema.tryParse,
      );
      expect(r, isA<ParseOk<P4Output>>());
      final v = (r as ParseOk<P4Output>).value;
      expect(v.picks.map((p) => p.id).toList(), ['passport', 'shaver']);
      expect(v.picks[0].why, '');
      expect(v.picks[1].why, '外出留宿要用');
      // why 缺省为空串，不影响这个条目本身被收下
      expect(v.maybe.single.id, 'powerstrip');
      expect(v.maybe.single.why, '');
      expect(v.missing, ['转换插头']);
    });

    test('P4 一档里有一个元素不合规 ⇒ 整档落空（catch 挂在数组上）', () {
      final r = parseModelJson(
        '{"picks":[{"id":"passport","why":"出境必备"},{"why":"没有 id"}],"answer":"ok"}',
        P4OutputSchema.tryParse,
      );
      final v = (r as ParseOk<P4Output>).value;
      expect(v.picks, isEmpty);
      // 另一档不受影响 —— 这是「逐字段容错」的意义
      expect(v.answer, 'ok');
    });

    test('P4 的 missing 混进非字符串 ⇒ 整档落空，但 answer 照样拿到', () {
      final r = parseModelJson('{"missing":["转换插头",5],"answer":"ok"}', P4OutputSchema.tryParse);
      final v = (r as ParseOk<P4Output>).value;
      expect(v.missing, isEmpty);
      expect(v.answer, 'ok');
    });

    test('顶层不是对象 ⇒ 失败（zod 的 z.object 对数组/标量都拒绝）', () {
      expect(parseModelJson<P4Output>('[1,2,3]', P4OutputSchema.tryParse), isA<ParseFailure<P4Output>>());
      expect(parseModelJson<P4Output>('"just a string"', P4OutputSchema.tryParse), isA<ParseFailure<P4Output>>());
    });
  });
}
