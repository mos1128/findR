import { expect, test } from 'vitest';
import { z } from 'zod';
import { parseModelJson, P1OutputSchema } from '../src/parse';

const Simple = z.object({ a: z.number() });

test('提取 markdown 围栏中的 JSON', () => {
  expect(parseModelJson('```json\n{"a":1}\n```', Simple)).toEqual({ ok: true, value: { a: 1 } });
});

test('提取被解释文字包围的 JSON', () => {
  expect(parseModelJson('好的，结果如下：{"a": 2} 以上。', Simple)).toEqual({
    ok: true,
    value: { a: 2 },
  });
});

test('修复尾逗号', () => {
  expect(parseModelJson('{"a": 1,}', Simple)).toEqual({ ok: true, value: { a: 1 } });
});

test('没有 JSON 时失败且不抛异常', () => {
  const r = parseModelJson('抱歉，我不知道你在说什么', Simple);
  expect(r.ok).toBe(false);
});

test('P1 schema：字段缺失走宽松缺省', () => {
  const r = parseModelJson('{"category":"物品存取","entity":"护照"}', P1OutputSchema);
  expect(r.ok).toBe(true);
  if (r.ok) {
    expect(r.value.desc).toBe('');
    expect(r.value.steps).toEqual([]);
    expect(r.value.aliases).toEqual([]);
    expect(r.value.path).toBeNull();
  }
});

test('P1 schema：模型多吐已废弃字段不影响解析（老提示词 / 缓存样本仍可用）', () => {
  const r = parseModelJson(
    '{"structure_type":"item","item_status":"in_stock","related_person":"老王","entity":"梯子"}',
    P1OutputSchema,
  );
  expect(r.ok).toBe(true);
  if (r.ok) expect(r.value.entity).toBe('梯子');
});

test('P1 schema：model 完全没给 JSON 才失败（触发待整理路径）', () => {
  expect(parseModelJson('我不知道该怎么整理这条', P1OutputSchema).ok).toBe(false);
});
