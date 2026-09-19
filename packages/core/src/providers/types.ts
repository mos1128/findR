/**
 * 送给主 LLM 的输入块。**刻意只有文本与图片** —— 语音不走这条路。
 *
 * 需求 3.2 原本还有一条「模式 1 · LLM 原生音频」（把音频塞进 chat 的 `input_audio`
 * 内容块让模型自己听），已于 2026-09-19 废止：格式各家不一、拿不到热词、
 * 成本与延迟都明显更高，且从 1.0 起就没有任何代码走过它。
 * 转写一律走 `ASRProviderAdapter.transcribe`（`/audio/transcriptions`）。
 */
export type Part =
  | { type: 'text'; text: string }
  | { type: 'image'; mime: string; base64: string };

export interface ChatRequest {
  system: string;
  parts: Part[];
  temperature?: number;
  maxTokens?: number;
  timeoutMs?: number;
  signal?: AbortSignal;
}

export interface ChatResponse {
  text: string;
  /**
   * 思考型模型的过程文本（DeepSeek 的 `reasoning_content`）。默认不参与业务逻辑，
   * 只在 text 为空时用来解释「为什么是空的」：思考模式默认开启且会吃掉 max_tokens 预算，
   * 额度不够时正文可以是空的，此时它往往是唯一产出。
   */
  reasoning?: string;
  usage?: { inputTokens?: number; outputTokens?: number };
}

/** 带 HTTP 状态码的调用失败。调用方据此区分「认证 / 模型名 / 限流」与「端点不接受这种输入」 */
export interface HttpStatusError extends Error {
  status: number;
  body: string;
}

export function httpStatusError(prefix: string, status: number, body: string): HttpStatusError {
  const err = new Error(`${prefix} 调用失败 HTTP ${status}: ${body.slice(0, 300)}`) as HttpStatusError;
  err.name = 'HttpStatusError';
  err.status = status;
  err.body = body;
  return err;
}

/**
 * 音频引用。走原生文件直传，m4a 不进 JS 内存；
 * base64 分支供 node 测试与设置页的 ASR 槽探测（内嵌 1 秒 WAV）使用。
 */
export type AudioRef =
  | { kind: 'file'; rel: string; mime: string }
  | { kind: 'base64'; base64: string; mime: string };

export interface TranscribeRequest {
  audio: AudioRef;
  /** 上传文件名，部分服务端靠后缀嗅探格式 */
  filename?: string;
  lang?: string;
  hotwords?: string[];
  timeoutMs?: number;
}

export interface ProviderConfig {
  providerType: 'openai-compat' | 'anthropic' | 'gemini' | 'fake';
  baseUrl?: string;
  model: string;
  apiKey?: string;
  /** 认证头风格：Anthropic 原生用 x-api-key；本地网关（如 ccg-gateway）用 bearer */
  authStyle?: 'x-api-key' | 'bearer';
  /** 部分网关按 User-Agent 路由，需要伪装成已知客户端（如 claude-cli/…） */
  userAgent?: string;
}

export interface LLMProviderAdapter {
  chat(req: ChatRequest, cfg: ProviderConfig): Promise<ChatResponse>;
}

export interface ASRProviderAdapter {
  transcribe(req: TranscribeRequest, cfg: ProviderConfig): Promise<{ text: string }>;
}
