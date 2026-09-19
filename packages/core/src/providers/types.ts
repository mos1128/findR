export type Part =
  | { type: 'text'; text: string }
  | { type: 'image'; mime: string; base64: string }
  | { type: 'audio'; mime: string; base64: string };

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
 * 适配器在本地就判定「这个协议不支持某种输入」（还没发出去，或协议层面就没有这种字段）。
 * 与服务端拒绝要分开：两者都算能力缺失，但前者是我们自己知道的确定结论。
 */
export interface UnsupportedInputError extends Error {
  unsupportedInput: true;
}

export function unsupportedInput(message: string): UnsupportedInputError {
  const err = new Error(message) as UnsupportedInputError;
  err.name = 'UnsupportedInputError';
  err.unsupportedInput = true;
  return err;
}

/**
 * 音频引用。模式 2（/audio/transcriptions）走原生文件直传，m4a 不进 JS 内存；
 * base64 分支供 node 测试与模式 1（chat 的 input_audio）使用。
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
