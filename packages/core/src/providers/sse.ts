/**
 * 共享 SSE 读取：网关常强制流式返回，两种协议的差异只在「从事件载荷里取哪段文本」。
 * Anthropic 与 OpenAI 的 delta 结构完全不同，所以抽的是读取骨架而不是解析结果。
 */

export type SseDeltaExtractor = (event: Record<string, unknown>) => string;

export async function readSseText(res: Response, extract: SseDeltaExtractor): Promise<string> {
  const reader = res.body?.getReader();
  if (!reader) return '';
  const decoder = new TextDecoder();
  let buffer = '';
  let out = '';

  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split('\n');
    buffer = lines.pop() ?? '';
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed.startsWith('data:')) continue;
      const payload = trimmed.slice(5).trim();
      if (!payload || payload === '[DONE]') continue;
      try {
        out += extract(JSON.parse(payload) as Record<string, unknown>);
      } catch {
        // 跳过非 JSON 的事件行（注释、心跳等）
      }
    }
  }
  return out;
}

/** Anthropic Messages：content_block_delta + delta.text_delta */
export function anthropicDelta(event: Record<string, unknown>): string {
  const e = event as { type?: string; delta?: { type?: string; text?: string } };
  if (e.type !== 'content_block_delta') return '';
  if (e.delta?.type !== 'text_delta') return '';
  return typeof e.delta.text === 'string' ? e.delta.text : '';
}

/** OpenAI chat/completions：choices[0].delta.content */
export function openaiDelta(event: Record<string, unknown>): string {
  const e = event as { choices?: Array<{ delta?: { content?: string | null } }> };
  const content = e.choices?.[0]?.delta?.content;
  return typeof content === 'string' ? content : '';
}
