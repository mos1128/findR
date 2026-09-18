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
  usage?: { inputTokens?: number; outputTokens?: number };
}

export interface TranscribeRequest {
  audioBase64: string;
  mime: string;
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
