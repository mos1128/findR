/** 卡片里的数组/对象类列统一以 JSON 文本存储，这里收口两个方向的转换 */

export function toJson(value: unknown[] | null | undefined): string | null {
  return value == null ? null : JSON.stringify(value);
}

export function parseJsonArray<T>(value: unknown): T[] | null {
  if (value == null) return null;
  try {
    return JSON.parse(String(value)) as T[];
  } catch {
    return null;
  }
}
