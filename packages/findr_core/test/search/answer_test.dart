import 'dart:convert';

import 'package:findr_core/findr_core.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// L2（答案组织）—— 对应 `packages/core/test/answer.test.ts`。
///
/// 这一层的硬约束是**只送命中片段、永不发全库**（需求 5.3）。
/// 所以这里的用例大多在盯同一件事：**发出去的那段文本里有什么、没什么**。
const cfg = ProviderConfig(providerType: ProviderType.fake, model: 'fake');

String p3([Map<String, Object?> over = const {}]) => jsonEncode({
  'answer': '护照在书房抽屉的文件袋里。',
  'hit_ids': ['c1'],
  'suggest': '',
  ...over,
});

String textOf(ChatRequest req) =>
    req.parts.map((p) => p is TextPart ? p.text : '').join();

void main() {
  group('formatSnippets', () {
    test('片段块带上 id 与关键字段，模型要靠 id 回指卡片', () {
      final text = formatSnippets([
        makeCard(
          id: 'c1',
          entity: '护照',
          pathNames: '书房/抽屉',
          desc: '护照放在书房抽屉的文件袋里。',
          transcript: '护照放书房抽屉了',
          createdAt: '2026-03-01T12:00:00.000Z',
        ),
      ]);
      expect(text, contains('id=c1'));
      expect(text, contains('位置：书房/抽屉'));
      expect(text, contains('实体：护照'));
      expect(text, contains('描述：护照放在书房抽屉的文件袋里。'));
      expect(text, contains('记录时间：2026-03-01'));
    });

    test('原文与描述相同时不重复输出', () {
      final text = formatSnippets([
        makeCard(id: 'c1', desc: '同一段话', transcript: '同一段话'),
      ]);
      expect(RegExp('同一段话').allMatches(text).length, 1);
    });

    test('超长文本被截断，片段数有上限（请求体必须有上界）', () {
      final long = '很长的一段描述' * 100;
      final text = formatSnippets([makeCard(id: 'c1', desc: long)]);
      expect(text.length, lessThan(long.length));

      final many = <MemoryCard>[
        for (var i = 0; i < 20; i++) makeCard(id: 'c$i', desc: 'x'),
      ];
      final snippets = formatSnippets(many);
      expect(RegExp(r'id=c\d+').allMatches(snippets).length, l2MaxSnippets);
    });

    test('没有命中片段时给出明确占位，而不是空白', () {
      expect(formatSnippets(const <MemoryCard>[]), '（没有命中任何片段）');
    });

    test('字段为空时不产出空行（位置 / 实体 / 描述都可能没有）', () {
      final text = formatSnippets([
        makeCard(id: 'c1', entity: '', pathNames: null, desc: null, transcript: null),
      ]);
      expect(text, contains('id=c1'));
      expect(text, isNot(contains('位置：')));
      expect(text, isNot(contains('实体：')));
      expect(text, isNot(contains('描述：')));
      // 只有记录时间是恒有的
      expect(text, contains('记录时间：'));
    });
  });

  group('answerFromCards', () {
    test('只把命中片段送出去，绝不发全库', () async {
      final llm = FakeLlmAdapter([p3()]);
      final cards = [
        makeCard(id: 'c1', entity: '护照', desc: '护照在书房'),
        makeCard(id: 'c2', entity: '猫砂', desc: '猫砂在阳台'),
      ];
      final res = await answerFromCards(
        AnswerDeps(llm: llm, cfg: cfg),
        '护照在哪',
        cards,
      );

      expect(res.ok, isTrue);
      expect(res.answer, contains('护照'));

      final body = textOf(llm.requests[0]);
      expect(body, contains('c1'));
      // 候选里有的都在，候选外的不可能被送出去（这里用「只送前 N 条」的上界保证）
      expect(llm.requests[0].parts, hasLength(1));
    });

    test('模型编出来的 hit_ids 会被丢掉，避免高亮指向不存在的卡', () async {
      final llm = FakeLlmAdapter([
        p3({'hit_ids': ['c1', 'c_不存在', '另一个幻觉']}),
      ]);
      final res = await answerFromCards(
        AnswerDeps(llm: llm, cfg: cfg),
        'q',
        [makeCard(id: 'c1')],
      );
      expect(res.hitIds, ['c1']);
    });

    test('本地无结果时仍然调用（P3 的职责是说明没找到 + 缺什么线索）', () async {
      final llm = FakeLlmAdapter([
        jsonEncode({
          'answer': '没找到相关记录。',
          'hit_ids': <String>[],
          'suggest': '换个说法或先记一笔',
        }),
      ]);
      final res = await answerFromCards(
        AnswerDeps(llm: llm, cfg: cfg),
        '不存在的东西',
        const <MemoryCard>[],
      );
      expect(res.ok, isTrue);
      expect(res.suggest, '换个说法或先记一笔');
      expect(textOf(llm.requests[0]), contains('没有命中任何片段'));
    });

    test('模型输出不是 JSON 时安全失败，不抛异常', () async {
      final res = await answerFromCards(
        AnswerDeps(llm: FakeLlmAdapter(['抱歉我做不到']), cfg: cfg),
        'q',
        const <MemoryCard>[],
      );
      expect(res.ok, isFalse);
      expect(res.answer, '');
      expect(res.error, isNotNull);
    });

    test('模型调用失败时安全失败', () async {
      final res = await answerFromCards(
        AnswerDeps(llm: FakeLlmAdapter(), cfg: cfg),
        'q',
        const <MemoryCard>[],
      );
      expect(res.ok, isFalse);
      expect(res.error, contains('无预置响应'));
    });

    test('P3 用到的系统提示词就是那一份（约束不许被绕过）', () async {
      final llm = FakeLlmAdapter([p3()]);
      await answerFromCards(
        AnswerDeps(llm: llm, cfg: cfg),
        'q',
        [makeCard(id: 'c1')],
      );
      expect(
        llm.requests[0].system,
        contains('只能依据给出的片段，不得补充片段之外的任何信息'),
      );
    });
  });
}
