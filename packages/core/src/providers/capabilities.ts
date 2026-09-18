import { testPngBase64, testWavBase64 } from './samples';
import type { LLMProviderAdapter, Part, ProviderConfig } from './types';

export type CapabilityKind = 'vision' | 'audio';

export interface CapabilityResult {
  ok: boolean;
  /** 通过时是模型回显，失败时是错误原因 */
  detail: string;
}

/**
 * 能力探测：用内嵌微型样本各发一次 chat，能正常返回即视为该能力可用（技术设计四）。
 *
 * 注意「用户主动关闭图片分析」与「模型不支持图片」是两回事（需求 5.1）：
 * 这里探测的是后者，结果只用于把图片分析开关置灰锁定，以及决定 ASR 模式 1 是否可用。
 */
export async function probeCapability(
  adapter: LLMProviderAdapter,
  cfg: ProviderConfig,
  kind: CapabilityKind,
): Promise<CapabilityResult> {
  const part: Part =
    kind === 'vision'
      ? { type: 'image', mime: 'image/png', base64: testPngBase64() }
      : { type: 'audio', mime: 'audio/wav', base64: testWavBase64() };

  try {
    const res = await adapter.chat(
      {
        system: '这是一次能力探测，请只回答要求的短语。',
        parts: [
          {
            type: 'text',
            text:
              kind === 'vision'
                ? '这张图的图案是什么？用不超过五个字回答。'
                : '确认你能收到这段音频，回复「ok」即可。',
          },
          part,
        ],
        temperature: 0,
        maxTokens: 64,
        timeoutMs: 60_000,
      },
      cfg,
    );
    const text = res.text.trim();
    if (!text) return { ok: false, detail: '模型返回为空' };
    return { ok: true, detail: text.slice(0, 60) };
  } catch (e) {
    // 适配器自身的「不支持音频」也算作能力缺失，而不是调用失败
    return { ok: false, detail: e instanceof Error ? e.message : String(e) };
  }
}

export interface ProbedCapabilities {
  vision: boolean;
  audio: boolean;
  visionDetail: string;
  audioDetail: string;
}

export async function probeLlm(
  adapter: LLMProviderAdapter,
  cfg: ProviderConfig,
): Promise<ProbedCapabilities> {
  const [vision, audio] = await Promise.all([
    probeCapability(adapter, cfg, 'vision'),
    probeCapability(adapter, cfg, 'audio'),
  ]);
  return {
    vision: vision.ok,
    audio: audio.ok,
    visionDetail: vision.detail,
    audioDetail: audio.detail,
  };
}
