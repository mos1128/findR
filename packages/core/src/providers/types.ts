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
}

export interface LLMProviderAdapter {
  chat(req: ChatRequest, cfg: ProviderConfig): Promise<ChatResponse>;
}

export interface ASRProviderAdapter {
  transcribe(req: TranscribeRequest, cfg: ProviderConfig): Promise<{ text: string }>;
}
