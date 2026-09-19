import { getSetting, setSetting } from './db/settings';
import type { SqliteDriver } from './db/driver';

/**
 * 设置项的唯一权威定义。DB 的 settings 表只存这里列出的非机密项；
 * API Key 只进 SecureStore（键 llm / asr），导出备份永不包含（技术设计四）。
 */
export const SETTINGS_KEYS = {
  llm: 'llm',
  asr: 'asr',
  capture: 'capture',
  pipeline: 'pipeline',
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
  audio: boolean;
  visionDetail: string;
  audioDetail: string;
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
