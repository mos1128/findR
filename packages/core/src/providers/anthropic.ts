import type { ChatRequest, ChatResponse, LLMProviderAdapter, ProviderConfig } from './types';

export interface AnthropicAdapterOptions {
  fetchFn?: typeof fetch;
  timeoutMs?: number;
}

/** baseUrl 形如 https://host 或 https://host/v1，均归一到 …/v1/messages */
function messagesUrl(baseUrl: string): string {
  const base = baseUrl.replace(/\/+$/, '');
  return /\/v1$/.test(base) ? `${base}/messages` : `${base}/v1/messages`;
}

interface AnthropicMessageResponse {
  content?: Array<{ type?: string; text?: string }>;
  usage?: { input_tokens?: number; output_tokens?: number };
}

/** 网关常强制 SSE 流式返回：兜底解析 content_block_delta 文本增量 */
async function readSseText(res: Response): Promise<string> {
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
        const evt = JSON.parse(payload) as {
          type?: string;
          delta?: { type?: string; text?: string };
        };
        if (
          evt.type === 'content_block_delta' &&
          evt.delta?.type === 'text_delta' &&
          typeof evt.delta.text === 'string'
        ) {
          out += evt.delta.text;
        }
      } catch {
        // 跳过非 JSON 事件行
      }
    }
  }
  return out;
}

/**
 * Anthropic Messages 协议适配器（/v1/messages）。
 * 兼容 ccg-gateway 等本地网关：authStyle='bearer' + userAgent 伪装 claude-cli。
 * 不支持音频输入（Anthropic 协议限制，走专用 ASR）。
 */
export class AnthropicAdapter implements LLMProviderAdapter {
  private readonly fetchFn: typeof fetch;
  private readonly timeoutMs: number;

  constructor(opts: AnthropicAdapterOptions = {}) {
    this.fetchFn = opts.fetchFn ?? fetch;
    this.timeoutMs = opts.timeoutMs ?? 120_000;
  }

  async chat(req: ChatRequest, cfg: ProviderConfig): Promise<ChatResponse> {
    if (!cfg.baseUrl) throw new Error('anthropic 适配器需要 baseUrl');

    const content: unknown[] = [];
    for (const p of req.parts) {
      if (p.type === 'text') content.push({ type: 'text', text: p.text });
      else if (p.type === 'image')
        content.push({
          type: 'image',
          source: { type: 'base64', media_type: p.mime, data: p.base64 },
        });
      else throw new Error('anthropic 适配器不支持音频输入（请配置专用 ASR）');
    }

    const headers: Record<string, string> = {
      'content-type': 'application/json',
      accept: 'application/json',
      'anthropic-version': '2023-06-01',
    };
    if (cfg.authStyle === 'bearer') headers.authorization = `Bearer ${cfg.apiKey ?? ''}`;
    else headers['x-api-key'] = cfg.apiKey ?? '';
    if (cfg.userAgent) headers['user-agent'] = cfg.userAgent;

    const body = {
      model: cfg.model,
      max_tokens: req.maxTokens ?? 4096,
      temperature: req.temperature,
      system: req.system,
      messages: [{ role: 'user', content }],
    };

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), req.timeoutMs ?? this.timeoutMs);
    const onAbort = () => controller.abort();
    if (req.signal) {
      if (req.signal.aborted) controller.abort();
      else req.signal.addEventListener('abort', onAbort, { once: true });
    }

    try {
      const res = await this.fetchFn(messagesUrl(cfg.baseUrl), {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
        signal: controller.signal,
      });
      if (!res.ok) {
        const text = await res.text().catch(() => '');
        throw new Error(`anthropic 调用失败 HTTP ${res.status}: ${text.slice(0, 300)}`);
      }
      const ctype = res.headers.get('content-type') ?? '';
      if (ctype.includes('text/event-stream')) {
        return { text: await readSseText(res) };
      }
      const data = (await res.json()) as AnthropicMessageResponse;
      const text = (data.content ?? [])
        .filter((b) => b.type === 'text' && typeof b.text === 'string')
        .map((b) => b.text ?? '')
        .join('');
      return {
        text,
        usage: data.usage
          ? { inputTokens: data.usage.input_tokens, outputTokens: data.usage.output_tokens }
          : undefined,
      };
    } finally {
      clearTimeout(timer);
      req.signal?.removeEventListener('abort', onAbort);
    }
  }
}
