import { AnthropicAdapter } from './anthropic';
import type { MediaIO } from './media';
import { OpenAICompatAdapter, OpenAICompatAsrAdapter } from './openai-compat';
import type { ASRProviderAdapter, LLMProviderAdapter, ProviderConfig } from './types';
import type { AsrSettings, LlmSettings } from '../settings';

export interface AdapterOptions {
  fetchFn?: typeof fetch;
  timeoutMs?: number;
}

/** 设置项 + Key（Key 由调用方从 SecureStore 取出）→ 适配器可用的配置 */
export function toProviderConfig(llm: LlmSettings, apiKey: string | null): ProviderConfig {
  return {
    providerType: llm.providerType,
    baseUrl: llm.baseUrl,
    model: llm.model,
    apiKey: apiKey ?? undefined,
    authStyle: llm.authStyle,
    userAgent: llm.userAgent,
  };
}

export function makeLlmAdapter(llm: LlmSettings, opts: AdapterOptions = {}): LLMProviderAdapter {
  switch (llm.providerType) {
    case 'anthropic':
      return new AnthropicAdapter(opts);
    case 'openai-compat':
      return new OpenAICompatAdapter(opts);
  }
}

export function toAsrProviderConfig(asr: AsrSettings, apiKey: string | null): ProviderConfig {
  return {
    providerType: asr.providerType,
    baseUrl: asr.baseUrl,
    model: asr.model,
    apiKey: apiKey ?? undefined,
  };
}

export function makeAsrAdapter(
  asr: AsrSettings,
  media: MediaIO,
  opts: AdapterOptions = {},
): ASRProviderAdapter {
  switch (asr.providerType) {
    case 'openai-compat':
      return new OpenAICompatAsrAdapter({ ...opts, media });
  }
}
