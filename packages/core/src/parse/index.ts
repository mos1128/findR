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
  structure_type: z.enum(['item', 'todo', 'procedure']),
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

export const P2OutputSchema = z.object({
  intent: z.enum(['find_item', 'list_todo', 'recall_steps', 'unknown']).catch('unknown'),
  keywords: z.array(z.string()).catch([]),
  synonyms: z.array(z.string()).catch([]),
  category: z.string().nullable().catch(null),
  path_prefix: z.array(z.string()).nullable().catch(null),
  time_hint: z.enum(['recent', 'this_week', 'this_month', 'this_year']).nullish(),
  match_mode: z.enum(['any', 'all']).catch('any'),
  normalized_query: z.string().nullish(),
});
export type P2Output = z.infer<typeof P2OutputSchema>;

export const P3OutputSchema = z.object({
  answer: z.string().catch(''),
  hit_ids: z.array(z.string()).catch([]),
  suggest: z.string().catch(''),
});
export type P3Output = z.infer<typeof P3OutputSchema>;
