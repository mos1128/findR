import { expect, test } from 'vitest';
import { answerFromCards, formatSnippets, L2_MAX_SNIPPETS } from '../src/search/answer';
import { FakeLLMAdapter } from '../src/providers/fake';
import type { ProviderConfig } from '../src/providers/types';
import { makeCard } from './helpers';

const CFG: ProviderConfig = { providerType: 'fake', model: 'fake' };

const p3 = (over: Record<string, unknown> = {}) =>
  JSON.stringify({ answer: '护照在书房抽屉的文件袋里。', hit_ids: ['c1'], suggest: '', ...over });

test('片段块带上 id 与关键字段，模型要靠 id 回指卡片', () => {
  const text = formatSnippets([
    makeCard({
      id: 'c1',
      entity: '护照',
      pathNames: '书房/抽屉',
      desc: '护照放在书房抽屉的文件袋里。',
      transcript: '护照放书房抽屉了',
      createdAt: '2026-03-01T12:00:00.000Z',
    }),
  ]);
  expect(text).toContain('id=c1');
  expect(text).toContain('位置：书房/抽屉');
  expect(text).toContain('实体：护照');
  expect(text).toContain('描述：护照放在书房抽屉的文件袋里。');
  expect(text).toContain('记录时间：2026-03-01');
});

test('原文与描述相同时不重复输出', () => {
  const text = formatSnippets([makeCard({ id: 'c1', desc: '同一段话', transcript: '同一段话' })]);
  expect(text.match(/同一段话/g)).toHaveLength(1);
});

test('超长文本被截断，片段数有上限（请求体必须有上界）', () => {
  const long = '很长的一段描述'.repeat(100);
  const text = formatSnippets([makeCard({ id: 'c1', desc: long })]);
  expect(text.length).toBeLessThan(long.length);

  const many = Array.from({ length: 20 }, (_, i) => makeCard({ id: `c${i}`, desc: 'x' }));
  const snippets = formatSnippets(many);
  expect(snippets.match(/id=c\d+/g)).toHaveLength(L2_MAX_SNIPPETS);
});

test('没有命中片段时给出明确占位，而不是空白', () => {
  expect(formatSnippets([])).toBe('（没有命中任何片段）');
});

test('answerFromCards 只把命中片段送出去，绝不发全库', async () => {
  const llm = new FakeLLMAdapter([p3()]);
  const cards = [
    makeCard({ id: 'c1', entity: '护照', desc: '护照在书房' }),
    makeCard({ id: 'c2', entity: '猫砂', desc: '猫砂在阳台' }),
  ];
  const res = await answerFromCards({ llm, cfg: CFG }, '护照在哪', cards);

  expect(res.ok).toBe(true);
  expect(res.answer).toContain('护照');

  const body = JSON.stringify(llm.requests[0].parts);
  expect(body).toContain('c1');
  // 候选里有的都在，候选外的不可能被送出去（这里用「只送前 N 条」的上界保证）
  expect(llm.requests[0].parts).toHaveLength(1);
});

test('模型编出来的 hit_ids 会被丢掉，避免高亮指向不存在的卡', async () => {
  const llm = new FakeLLMAdapter([p3({ hit_ids: ['c1', 'c_不存在', '另一个幻觉'] })]);
  const res = await answerFromCards({ llm, cfg: CFG }, 'q', [makeCard({ id: 'c1' })]);
  expect(res.hitIds).toEqual(['c1']);
});

test('本地无结果时仍然调用（P3 的职责是说明没找到 + 缺什么线索）', async () => {
  const llm = new FakeLLMAdapter([
    JSON.stringify({ answer: '没找到相关记录。', hit_ids: [], suggest: '换个说法或先记一笔' }),
  ]);
  const res = await answerFromCards({ llm, cfg: CFG }, '不存在的东西', []);
  expect(res.ok).toBe(true);
  expect(res.suggest).toBe('换个说法或先记一笔');
  expect(JSON.stringify(llm.requests[0].parts)).toContain('没有命中任何片段');
});

test('模型输出不是 JSON 时安全失败，不抛异常', async () => {
  const res = await answerFromCards({ llm: new FakeLLMAdapter(['抱歉我做不到']), cfg: CFG }, 'q', []);
  expect(res.ok).toBe(false);
  expect(res.answer).toBe('');
  expect(res.error).toBeTruthy();
});

test('模型调用失败时安全失败', async () => {
  const res = await answerFromCards({ llm: new FakeLLMAdapter(), cfg: CFG }, 'q', []);
  expect(res.ok).toBe(false);
  expect(res.error).toContain('无预置响应');
});
