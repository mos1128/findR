import { z } from 'zod';

/** 提取模型输出中的 JSON 对象：先剥 markdown 围栏，再取首个 { 到末个 } */
export function extractJson(raw: string): string | null {
  let text = raw.trim();
  const fence = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fence) text = fence[1].trim();
  const first = text.indexOf('{');
  const last = text.lastIndexOf('}');
  if (first === -1 || last <= first) return null;
  return text.slice(first, last + 1);
}

/** 修复高频语法问题：尾逗号 */
export function fixJson(text: string): string {
  return text.replace(/,\s*([}\]])/g, '$1');
}

export type ParseResult<T> = { ok: true; value: T } | { ok: false; error: string };

export function parseModelJson<T>(
  raw: string,
  schema: z.ZodType<T, z.ZodTypeDef, unknown>,
): ParseResult<T> {
  const extracted = extractJson(raw);
  if (!extracted) return { ok: false, error: '输出中未找到 JSON 对象' };
  try {
    const obj: unknown = JSON.parse(fixJson(extracted));
    const r = schema.safeParse(obj);
    return r.success ? { ok: true, value: r.data } : { ok: false, error: r.error.message };
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
}

export const P1OutputSchema = z.object({
  category: z.string().nullable().catch(null),
  entity: z.string().catch(''),
  aliases: z.array(z.string()).catch([]),
  path: z.array(z.string()).nullable().catch(null),
  path_matched: z.boolean().nullish(),
  path_suggestion: z.string().nullish(),
  steps: z.array(z.string()).catch([]),
  desc: z.string().catch(''),
  tags: z.array(z.string()).catch([]),
  confidence: z
    .number()
    .min(0)
    .max(1)
    .nullish()
    .catch(undefined),
  missing: z.array(z.string()).catch([]),
  ask: z.string().catch(''),
});
export type P1Output = z.infer<typeof P1OutputSchema>;

/**
 * 检索走哪条路（需求 5.3）：
 * - `locate` 定位题：用户知道自己要什么，本地字面检索能答（「我护照放哪了」）
 * - `advise` 推理题：用户给一个情景问「需要什么」，字面检索**必然 0 条** ——
 *   因为「护照」这两个字永远不会出现在「出国玩该带什么」里，答案要靠常识
 *   把情景与库存连起来（见 search/advise.ts）
 *
 * 缺省 `locate`：模型不认得这个字段时，行为与第十四版完全一致，不会更糟。
 */
export const P2OutputSchema = z.object({
  mode: z.enum(['locate', 'advise']).catch('locate'),
  intent: z.enum(['find_item', 'list_todo', 'recall_steps', 'unknown']).catch('unknown'),
  keywords: z.array(z.string()).catch([]),
  synonyms: z.array(z.string()).catch([]),
  category: z.string().nullable().catch(null),
  path_prefix: z.array(z.string()).nullable().catch(null),
  time_hint: z.enum(['recent', 'this_week', 'this_month', 'this_year']).nullish(),
  match_mode: z.enum(['any', 'all']).catch('any'),
  /** 仅 advise：一句话情景，供裁决时锁定判断范围（如「出国旅游」） */
  scenario: z.string().nullish(),
  /** 仅 advise：该情景通常需要的**类别**（不是具体物品名），用于给裁决提供方向 */
  aspects: z.array(z.string()).catch([]),
  normalized_query: z.string().nullish(),
});
export type P2Output = z.infer<typeof P2OutputSchema>;

/**
 * 裁决条目：模型可以只回 id 字符串，也可以回 `{id, why}`。
 * 两种都收 —— 让「结构更完整」不成为一次解析失败的理由。
 */
const AdviceRefSchema = z.union([
  z.object({ id: z.string(), why: z.string().catch('') }),
  z.string().transform((id) => ({ id, why: '' })),
]);

/**
 * P4 建议裁决的输出。
 *
 * 三档而不是二档：「必需 / 看情况」分开，是为了让「插线板」这类边界项能诚实表达成
 * 「看情况，取决于目的地插座标准」。二分类会逼模型二选一 —— 要么误删对的那条，
 * 要么为了保险全留下、退回成噪音（这正是第十四版之前的样子）。
 * 让助手说得出「这个看你情况」，是它和数据库的分界。
 */
export const P4OutputSchema = z.object({
  /** 必需：这个情景下没有它不行 */
  picks: z.array(AdviceRefSchema).catch([]),
  /** 看情况：可能要用，理由里必须写清取决于什么 */
  maybe: z.array(AdviceRefSchema).catch([]),
  /** 库里没有、但这个情景确实需要的东西（助手的义务：说「你没有的」） */
  missing: z.array(z.string()).catch([]),
  answer: z.string().catch(''),
});
export type P4Output = z.infer<typeof P4OutputSchema>;

export const P3OutputSchema = z.object({
  answer: z.string().catch(''),
  hit_ids: z.array(z.string()).catch([]),
  suggest: z.string().catch(''),
});
export type P3Output = z.infer<typeof P3OutputSchema>;
