/// 提示词自定义。
///
/// 押注点是三件容易被后来的改动悄悄破坏的事：
/// 1. `promptDefaultBody` 与内置常量**逐字一致** —— 不一致就会让所有老自定义一夜之间
///    被标成「默认已更新」，而用户什么也没做；
/// 2. 存了正文就真的发给模型（渲染层与调用点都得接上）；
/// 3. 认不出的数据不许炸页面。
library;

import 'dart:convert';

import 'package:findr_core/findr_core.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// 文本卡永远碰不到媒体端口，这里只是把参数位填上。
final class _NoMedia implements MediaIo {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const _cfg = ProviderConfig(providerType: ProviderType.fake, model: 'fake');

final _now = DateTime.parse('2026-03-01T12:00:00.000Z');

void main() {
  group('内置正文', () {
    test('四段都有正文，且带齐各自的变量', () {
      for (final id in PromptId.values) {
        final body = promptDefaultBody(id);
        expect(body.trim(), isNotEmpty, reason: id.wire);
        for (final v in promptVars(id)) {
          expect(body, contains('{{$v}}'), reason: '${id.wire} 缺 $v');
        }
      }
      expect(promptVars(PromptId.p3), isEmpty);
      expect(promptVars(PromptId.p4), isEmpty);
    });

    test('校验对内置正文一路放行', () {
      for (final id in PromptId.values) {
        expect(validatePromptBody(id, promptDefaultBody(id)), isNull, reason: id.wire);
      }
    });
  });

  group('读写', () {
    test('空库读出空表', () {
      final db = makeDb();
      expect(readPromptOverrides(db), isEmpty);
      expect(readPromptBody(db, PromptId.p1), isNull);
    });

    test('存了再读：去掉首尾空白，哈希盖的是当前默认', () {
      final db = makeDb();
      writePromptBody(db, PromptId.p1, '  我的录入规则 {{known}}  ');
      final o = readPromptOverrides(db)[PromptId.p1]!;
      expect(o.text, '我的录入规则 {{known}}');
      expect(o.preset, promptPresetHash(PromptId.p1));
      expect(readPromptBody(db, PromptId.p1), o.text);
    });

    test('把内置正文存回去等于没改（不留「改了但一样」的副本）', () {
      final db = makeDb();
      writePromptBody(db, PromptId.p2, promptDefaultBody(PromptId.p2));
      expect(readPromptOverrides(db), isEmpty);
    });

    test('重置只清那一条', () {
      final db = makeDb();
      writePromptBody(db, PromptId.p1, 'a {{known}}');
      writePromptBody(db, PromptId.p3, 'b');
      resetPromptBody(db, PromptId.p1);
      expect(readPromptOverrides(db).keys, [PromptId.p3]);
    });

    test('认不出的 id、空白正文都当没改（旧数据不该让页面炸）', () {
      final db = makeDb();
      setSetting(db, SettingsKeys.prompts, <String, Object?>{
        'p1': <String, Object?>{'text': 'x {{known}}', 'preset': 'deadbeef'},
        'p9': <String, Object?>{'text': '来路不明', 'preset': 'deadbeef'},
        'p2': <String, Object?>{'text': '   ', 'preset': 'deadbeef'},
        'p3': <String, Object?>{'text': '没有哈希的旧数据'},
      });
      final all = readPromptOverrides(db);
      expect(all.keys, [PromptId.p1, PromptId.p3]);
      expect(all[PromptId.p1]!.preset, 'deadbeef');
      // 缺哈希 ⇒ 按当前默认算，不打扰用户
      expect(all[PromptId.p3]!.preset, promptPresetHash(PromptId.p3));
    });

    test('默认改版后老自定义被标成「默认已更新」，「保留我的」把它盖回来', () {
      final db = makeDb();
      setSetting(db, SettingsKeys.prompts, <String, Object?>{
        'p1': <String, Object?>{'text': '我的 {{known}}', 'preset': '00000000'},
      });
      expect(
        readPromptOverrides(db)[PromptId.p1]!.preset,
        isNot(promptPresetHash(PromptId.p1)),
      );

      writePromptBody(db, PromptId.p1, '我的 {{known}}');
      expect(readPromptOverrides(db)[PromptId.p1]!.preset, promptPresetHash(PromptId.p1));
    });
  });

  group('校验', () {
    test('空正文', () {
      expect(validatePromptBody(PromptId.p1, ' \n '), '提示词不能为空。');
    });

    test('缺变量：点名缺的是哪一个', () {
      final err = validatePromptBody(PromptId.p1, '没有任何变量');
      expect(err, contains('{{categories}}'));
    });

    test('写了不存在的变量：点名写错的那个', () {
      // 变量齐了才轮到报「多出来的那个」；缺变量的提示优先级更高
      // （打错名字时「缺少 {{categories}}」正好指出该写什么）
      expect(
        validatePromptBody(PromptId.p1, '{{categories}}{{locations}}{{known}}{{nope}}'),
        contains('{{nope}}'),
      );
      // p3 本来就不接受变量
      expect(validatePromptBody(PromptId.p3, '{{known}}'), contains('不接受变量'));
      // 中文占位符渲染不到，也不能放过去
      expect(validatePromptBody(PromptId.p3, '{{记忆}}'), contains('不接受变量'));
    });

    test('过长', () {
      expect(validatePromptBody(PromptId.p3, 'x' * 20001), contains('20000'));
    });
  });

  group('正文注入', () {
    test('四段 system 都换用传进来的正文，schema 与示例照旧跟着走', () {
      final p1 = buildP1System(
        categories: '- 物品存取',
        locations: '主卧',
        body: '自定义 P1 {{categories}} {{known}}',
      );
      expect(p1, contains('自定义 P1'));
      expect(p1, contains('- 物品存取'));
      expect(p1, contains('（暂无）'));
      expect(p1, contains('输出 schema（字段名与类型不得改动）'));

      final p2 = buildP2System(categories: 'c', locations: 'l', body: '自定义 P2');
      expect(p2, contains('自定义 P2'));
      expect(p2, contains('输出 schema：'));
      // 内置规则被整段换掉，不该再夹带进来
      expect(p2, isNot(contains('match_mode 默认 any')));

      expect(buildP3System(body: '自定义 P3'), contains('自定义 P3'));
      expect(buildP4System(body: '自定义 P4'), contains('自定义 P4'));
    });
  });

  group('调用点', () {
    test('录入：改过的 P1 正文真的发给了模型', () async {
      final db = makeDb();
      writePromptBody(db, PromptId.p1, '我的录入规则 {{categories}} {{locations}} {{known}}');
      createDraft(
        db,
        const CaptureInput(source: SourceKind.text, text: '手电筒在衣柜'),
        id: 'c1',
      );
      final fake = FakeLlmAdapter([
        jsonEncode(<String, Object?>{
          'category': '物品存取',
          'entity': '手电筒',
          'desc': '手电筒放在衣柜里。',
        }),
      ]);

      await advanceCard(
        AdvanceDeps(
          db: db,
          llm: fake,
          cfg: _cfg,
          media: _NoMedia(),
          now: () => _now,
        ),
        'c1',
      );

      expect(fake.requests.single.system, contains('我的录入规则'));
    });

    test('检索：改过的 P2 正文真的发给了模型', () async {
      final db = makeDb();
      writePromptBody(db, PromptId.p2, '我的检索规则 {{categories}} {{locations}}');
      final fake = FakeLlmAdapter([
        jsonEncode(<String, Object?>{'mode': 'locate', 'keywords': <String>['手电筒']}),
      ]);

      await searchCards(SearchDeps(db: db, llm: fake, cfg: _cfg), '手电筒在哪');

      expect(fake.requests.single.system, contains('我的检索规则'));
    });

    test('回答与建议：正文由调用方交给 deps', () async {
      final answer = FakeLlmAdapter([
        jsonEncode(<String, Object?>{
          'answer': '在衣柜里。',
          'hit_ids': <String>['c1'],
          'suggest': '',
        }),
      ]);
      await answerFromCards(
        AnswerDeps(llm: answer, cfg: _cfg, promptBody: '我的回答规则'),
        '手电筒在哪',
        [makeCard(id: 'c1', entity: '手电筒', desc: '放在衣柜里。')],
      );
      expect(answer.requests.single.system, contains('我的回答规则'));

      final advise = FakeLlmAdapter([
        jsonEncode(<String, Object?>{
          'picks': <Object?>[],
          'maybe': <Object?>[],
          'missing': <String>[],
          'answer': '没有。',
        }),
      ]);
      await adviseFromInventory(
        AdviceDeps(llm: advise, cfg: _cfg, promptBody: '我的建议规则'),
        '出国带什么',
        '出国旅游',
        buildInventory(makeDb()),
      );
      expect(advise.requests.single.system, contains('我的建议规则'));
    });
  });
}
