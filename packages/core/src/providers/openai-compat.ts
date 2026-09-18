import { base64ToBytes } from '../util/base64';
import type { MediaIO } from './media';
import { openaiDelta, readSseText } from './sse';
import type {
  ASRProviderAdapter,
  ChatRequest,
  ChatResponse,
  LLMProviderAdapter,
  ProviderConfig,
  TranscribeRequest,
} from './types';

export interface OpenAICompatAdapterOptions {
  fetchFn?: typeof fetch;
  timeoutMs?: number;
}

export interface OpenAICompatAsrOptions extends OpenAICompatAdapterOptions {
  /** kind:'file' 时需要它把相对路径变成 FormData 能用的 part */
  media: MediaIO;
}

function resolveUrl(baseUrl: string | undefined, path: string): string {
  if (!baseUrl) throw new Error('openai-compat 适配器需要 baseUrl');
  const base = baseUrl.replace(/\/+$/, '');
  return /\/v1$/.test(base) ? `${base}${path}` : `${base}/v1${path}`;
}

function authHeaders(cfg: ProviderConfig): Record<string, string> {
  const headers: Record<string, string> = { authorization: `Bearer ${cfg.apiKey ?? ''}` };
  if (cfg.userAgent) headers['user-agent'] = cfg.userAgent;
  return headers;
}

function withTimeout(timeoutMs: number, signal?: AbortSignal) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const onAbort = () => controller.abort();
  if (signal) {
    if (signal.aborted) controller.abort();
    else signal.addEventListener('abort', onAbort, { once: true });
  }
  return {
    signal: controller.signal,
    done: () => {
      clearTimeout(timer);
      signal?.removeEventListener('abort', onAbort);
    },
  };
}

interface OpenAIChatResponse {
  choices?: Array<{ message?: { content?: string | null } }>;
  usage?: { prompt_tokens?: number; completion_tokens?: number };
}

/**
 * OpenAI 兼容协议适配器（/v1/chat/completions），覆盖 OpenAI、DeepSeek、通义、火山、GLM、
 * 硅基流动等一切兼容端点。图片走 image_url data URI，音频走 input_audio。
 */
export class OpenAICompatAdapter implements LLMProviderAdapter {
  private readonly fetchFn: typeof fetch;
  private readonly timeoutMs: number;

  constructor(opts: OpenAICompatAdapterOptions = {}) {
    this.fetchFn = opts.fetchFn ?? fetch;
    this.timeoutMs = opts.timeoutMs ?? 120_000;
  }

  async chat(req: ChatRequest, cfg: ProviderConfig): Promise<ChatResponse> {
    const url = resolveUrl(cfg.baseUrl, '/chat/completions');
    const content: unknown[] = [];
    for (const p of req.parts) {
      if (p.type === 'text') {
        content.push({ type: 'text', text: p.text });
      } else if (p.type === 'image') {
        content.push({
          type: 'image_url',
          image_url: { url: `data:${p.mime};base64,${p.base64}` },
        });
      } else {
        // chat 的 input_audio 只认 wav / mp3 —— m4a 必须走 /audio/transcriptions
        const format = p.mime.includes('wav') ? 'wav' : p.mime.includes('mp3') ? 'mp3' : null;
        if (!format) {
          throw new Error(
            `openai-compat 的 input_audio 只接受 wav/mp3，收到 ${p.mime}；m4a 请走专用 ASR（模式 2）`,
          );
        }
        content.push({ type: 'input_audio', input_audio: { data: p.base64, format } });
      }
    }

    const timeout = withTimeout(req.timeoutMs ?? this.timeoutMs, req.signal);
    try {
      const res = await this.fetchFn(url, {
        method: 'POST',
        headers: { ...authHeaders(cfg), 'content-type': 'application/json', accept: 'application/json' },
        body: JSON.stringify({
          model: cfg.model,
          temperature: req.temperature ?? 0.1,
          max_tokens: req.maxTokens ?? 4096,
          messages: [
            { role: 'system', content: req.system },
            { role: 'user', content },
          ],
        }),
        signal: timeout.signal,
      });
      if (!res.ok) {
        const text = await res.text().catch(() => '');
        throw new Error(`openai-compat 调用失败 HTTP ${res.status}: ${text.slice(0, 300)}`);
      }
      const ctype = res.headers.get('content-type') ?? '';
      if (ctype.includes('text/event-stream')) {
        return { text: await readSseText(res, openaiDelta) };
      }
      const data = (await res.json()) as OpenAIChatResponse;
      return {
        text: data.choices?.[0]?.message?.content ?? '',
        usage: data.usage
          ? { inputTokens: data.usage.prompt_tokens, outputTokens: data.usage.completion_tokens }
          : undefined,
      };
    } finally {
      timeout.done();
    }
  }
}

interface OpenAITranscriptionResponse {
  text?: string;
}

/** 上传文件名：没有显式给就用 mime 推一个，服务端常靠后缀嗅探格式 */
function filenameFor(req: TranscribeRequest): string {
  if (req.filename) return req.filename;
  const mime = req.audio.mime;
  if (mime.includes('wav')) return 'audio.wav';
  if (mime.includes('mp3') || mime.includes('mpeg')) return 'audio.mp3';
  if (mime.includes('webm')) return 'audio.webm';
  return 'audio.m4a';
}

/**
 * OpenAI 兼容 ASR（/v1/audio/transcriptions）。m4a 直传不转码。
 * 刻意不手写 content-type —— 交给 fetch 生成 multipart 的 boundary。
 */
export class OpenAICompatAsrAdapter implements ASRProviderAdapter {
  private readonly fetchFn: typeof fetch;
  private readonly timeoutMs: number;
  private readonly media: MediaIO;

  constructor(opts: OpenAICompatAsrOptions) {
    this.fetchFn = opts.fetchFn ?? fetch;
    this.timeoutMs = opts.timeoutMs ?? 60_000;
    this.media = opts.media;
  }

  async transcribe(req: TranscribeRequest, cfg: ProviderConfig): Promise<{ text: string }> {
    const url = resolveUrl(cfg.baseUrl, '/audio/transcriptions');
    const form = new FormData();
    form.append('model', cfg.model);
    if (req.lang) form.append('language', req.lang);
    // 需求 3.2：热词用来提升房间名与常用物品名的转写准确率
    if (req.hotwords && req.hotwords.length > 0) form.append('prompt', req.hotwords.join('、'));

    const filename = filenameFor(req);
    if (req.audio.kind === 'file') {
      // audioPart 的返回类型是 unknown：node 给 Blob，RN 给 { uri, name, type }，
      // 两边各自只认自己那种 part，core 不关心具体形状
      const part = await this.media.audioPart(req.audio.rel, req.audio.mime);
      form.append('file', part as Blob, filename);
    } else {
      const bytes = base64ToBytes(req.audio.base64);
      form.append('file', new Blob([bytes as BlobPart], { type: req.audio.mime }), filename);
    }

    const timeout = withTimeout(req.timeoutMs ?? this.timeoutMs);
    try {
      const res = await this.fetchFn(url, {
        method: 'POST',
        headers: authHeaders(cfg),
        body: form,
        signal: timeout.signal,
      });
      if (!res.ok) {
        const text = await res.text().catch(() => '');
        throw new Error(`ASR 调用失败 HTTP ${res.status}: ${text.slice(0, 300)}`);
      }
      const data = (await res.json()) as OpenAITranscriptionResponse;
      return { text: data.text ?? '' };
    } finally {
      timeout.done();
    }
  }
}
