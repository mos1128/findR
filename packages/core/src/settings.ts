import { getSetting, setSetting } from './db/settings';
import type { SqliteDriver } from './db/driver';
import type { CapabilityStatus } from './providers/capabilities';

/**
 * 设置项的唯一权威定义。DB 的 settings 表只存这里列出的非机密项；
 * API Key 只进 SecureStore（键 llm / asr），导出备份永不包含（技术设计四）。
 */
export const SETTINGS_KEYS = {
  llm: 'llm',
  asr: 'asr',
  capture: 'capture',
  pipeline: 'pipeline',
  search: 'search',
} as const;

export type LlmProviderType = 'anthropic' | 'openai-compat';

export interface CapabilityCache {
  /**
   * 纯文本连通性：跑通就说明「地址 / Key / 模型名」这几样没配错，
   * 图片与音频失败就只剩「能力缺失」一种解释。第十二版新增，旧缓存里没有这一项。
   */
  text?: boolean;
  textDetail?: string;
  vision: boolean;
  visionDetail: string;
  /** 图片能力的完整结论，用来在 UI 上区分「不支持」与「没测出来」。第十二版新增，旧缓存没有 */
  visionStatus?: CapabilityStatus;
  probedAt: string;
  /** 探测时的模型名；与当前模型不一致即视为过期，需要重探 */
  probedModel: string;
}

export interface LlmSettings {
  providerType: LlmProviderType;
  baseUrl?: string;
  model: string;
  authStyle?: 'x-api-key' | 'bearer';
  userAgent?: string;
  capabilities?: CapabilityCache;
}

export interface AsrSettings {
  providerType: 'openai-compat';
  baseUrl?: string;
  model: string;
}

export interface CaptureSettings {
  /** 图片分析开关的默认值（需求 5.1：默认开） */
  visionDefault: boolean;
  /** 记忆上次选择；null 表示用户还没手动切过 */
  visionLast: boolean | null;
  /** 单卡送模型分析的图片张数上限。需求把「可配 N 张」列为非 MVP，这里是固定护栏 */
  maxAnalyzeImages: number;
}

export interface PipelineSettings {
  /** 低于该置信度强制用户确认（需求 3.4） */
  confirmThreshold: number;
}

export const DEFAULT_CAPTURE_SETTINGS: CaptureSettings = {
  visionDefault: true,
  visionLast: null,
  maxAnalyzeImages: 6,
};

export const DEFAULT_PIPELINE_SETTINGS: PipelineSettings = {
  confirmThreshold: 0.6,
};

/**
 * 检索行为开关（第十四版新增）。
 *
 * `autoAnswer` 是把 L2 从「手动点」改成「自动补」的开关，默认**关**。
 * 关的理由不是省钱（单次多花的 token 换算下来约 0.17 分，可忽略），而是两条：
 * 1. **隐私**：L2 会把最多 8 条命中片段发给模型。关着的时候，用户不点按钮就**不外发任何记忆内容**；
 *    开着等于每次搜索都外发。对一个「本地记忆库」来说这是性质变化，必须由用户自己选。
 * 2. **冗余**：有结果时 L1 的卡片列表往往已经够用，一段总结常常只是把可扫的列表复述成要读的文字。
 *
 * 开启后答案**追加在列表下方**（不是置顶）—— 渐进式返回时置顶会把列表推下去，形成跳动。
 */
export interface SearchSettings {
  autoAnswer: boolean;
}

export const DEFAULT_SEARCH_SETTINGS: SearchSettings = {
  autoAnswer: false,
};

export function readSearchSettings(db: SqliteDriver): SearchSettings {
  return { ...DEFAULT_SEARCH_SETTINGS, ...(getSetting<SearchSettings>(db, SETTINGS_KEYS.search) ?? {}) };
}

export function writeSearchSettings(db: SqliteDriver, value: SearchSettings): void {
  setSetting(db, SETTINGS_KEYS.search, value);
}

export function readLlmSettings(db: SqliteDriver): LlmSettings | null {
  return getSetting<LlmSettings>(db, SETTINGS_KEYS.llm);
}

export function writeLlmSettings(db: SqliteDriver, value: LlmSettings): void {
  setSetting(db, SETTINGS_KEYS.llm, value);
}

export function readAsrSettings(db: SqliteDriver): AsrSettings | null {
  return getSetting<AsrSettings>(db, SETTINGS_KEYS.asr);
}

export function writeAsrSettings(db: SqliteDriver, value: AsrSettings): void {
  setSetting(db, SETTINGS_KEYS.asr, value);
}

export function readCaptureSettings(db: SqliteDriver): CaptureSettings {
  return { ...DEFAULT_CAPTURE_SETTINGS, ...(getSetting<CaptureSettings>(db, SETTINGS_KEYS.capture) ?? {}) };
}

export function writeCaptureSettings(db: SqliteDriver, value: CaptureSettings): void {
  setSetting(db, SETTINGS_KEYS.capture, value);
}

export function readPipelineSettings(db: SqliteDriver): PipelineSettings {
  return {
    ...DEFAULT_PIPELINE_SETTINGS,
    ...(getSetting<PipelineSettings>(db, SETTINGS_KEYS.pipeline) ?? {}),
  };
}

export function writePipelineSettings(db: SqliteDriver, value: PipelineSettings): void {
  setSetting(db, SETTINGS_KEYS.pipeline, value);
}

/**
 * 本次录入实际使用的图片分析开关：用户手动切过就用上次的选择，否则用默认值。
 * 模型不支持图片时恒定关（需求 3.3 置灰锁定）。
 */
export function effectiveVision(capture: CaptureSettings, visionSupported: boolean): boolean {
  if (!visionSupported) return false;
  return capture.visionLast ?? capture.visionDefault;
}

/** 探测结果是否已过期（换了模型就要重探） */
export function capabilitiesStale(llm: LlmSettings): boolean {
  const caps = llm.capabilities;
  if (!caps) return true;
  return caps.probedModel !== llm.model;
}
