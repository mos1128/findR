import { anthropicDelta, readSseText } from './sse';
import { httpStatusError } from './types';
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

/**
 * Anthropic Messages 协议适配器（/v1/messages）。
 *
 * **认证头自动适配，用户不需要选**（第十八版起）：
 *   - 默认发 `Authorization: Bearer` —— 官方文档现在的首选写法，网关也认这个；
 *   - **只有**收到 401 / 403（HTTP 层明确说「凭证不被接受」）才改用 `x-api-key` 重试一次。
 *     `x-api-key` 是官方标注的 legacy 兜底、仍受支持；留这一步只为兼容只认它的老端点。
 *   - 为什么不把两个头一起发：官方没有说明两者并存时用哪个，不猜。
 *   - 为什么只在 401/403 兜底：与「调用失败」和「能力不支持」必须分开判同源 ——
 *     其余错误一律不重试，别用它掩盖真实失败。
 *
 * 兼容 ccg-gateway 等本地网关：网关按 UA 路由，需 userAgent 伪装 claude-cli。
 * 只送文本与图片 —— 语音转写走专用 ASR（Anthropic 协议本身没有音频输入）。
 */
export class AnthropicAdapter implements LLMProviderAdapter {
  private readonly fetchFn: typeof fetch;
  private readonly timeoutMs: number;

  constructor(opts: AnthropicAdapterOptions = {}) {
    this.fetchFn = opts.fetchFn ?? fetch;
    this.timeoutMs = opts.timeoutMs ?? 120_000;
  }

  async chat(req: ChatRequest, cfg: ProviderConfig): Promise<ChatResponse> {
    // 取成局部常量：下面的闭包（重试用）里 TS 不会保留对 cfg.baseUrl 的收窄
    const baseUrl = cfg.baseUrl;
    if (!baseUrl) throw new Error('anthropic 适配器需要 baseUrl');

    const content: unknown[] = [];
    for (const p of req.parts) {
      if (p.type === 'text') content.push({ type: 'text', text: p.text });
      else
        content.push({
          type: 'image',
          source: { type: 'base64', media_type: p.mime, data: p.base64 },
        });
    }

    const baseHeaders: Record<string, string> = {
      'content-type': 'application/json',
      accept: 'application/json',
      'anthropic-version': '2023-06-01',
    };
    if (cfg.userAgent) baseHeaders['user-agent'] = cfg.userAgent;

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

    const send = (auth: Record<string, string>) =>
      this.fetchFn(messagesUrl(baseUrl), {
        method: 'POST',
        headers: { ...baseHeaders, ...auth },
        body: JSON.stringify(body),
        signal: controller.signal,
      });

    try {
      let res = await send({ authorization: `Bearer ${cfg.apiKey ?? ''}` });
      // 只有 HTTP 层明确拒绝凭证（401/403）才换 legacy 头发第二次；其余错误照原样抛出
      if (res.status === 401 || res.status === 403) {
        // 先把上一个响应体读完，别留下未消费的响应（这条路很少走到，成本可忽略）
        await res.text().catch(() => '');
        res = await send({ 'x-api-key': cfg.apiKey ?? '' });
      }
      if (!res.ok) {
        const text = await res.text().catch(() => '');
        throw httpStatusError('anthropic', res.status, text);
      }
      const ctype = res.headers.get('content-type') ?? '';
      if (ctype.includes('text/event-stream')) {
        return { text: await readSseText(res, anthropicDelta) };
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
