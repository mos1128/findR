import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import type { PropsWithChildren } from 'react';
import {
  capabilitiesStale,
  effectiveVision,
  makeAsrAdapter,
  makeLlmAdapter,
  migrate,
  readAsrSettings,
  readCaptureSettings,
  readLlmSettings,
  readPipelineSettings,
  runQueue,
  searchCards,
  toAsrProviderConfig,
  toProviderConfig,
  type AdvanceDeps,
  type AsrSettings,
  type CaptureSettings,
  type LlmSettings,
  type PipelineSettings,
  type QueueRunResult,
  type SqliteDriver,
} from '@findr/core';

import { getApiKey } from './secure';
import { deviceMediaIO } from './media';
import { openFindrDb } from './db';

export interface RuntimeState {
  driver: SqliteDriver;
  dbPath: string;
  llm: LlmSettings | null;
  asr: AsrSettings | null;
  capture: CaptureSettings;
  pipeline: PipelineSettings;
  llmKey: string | null;
  asrKey: string | null;
}

let opened: { driver: SqliteDriver; path: string } | null = null;

/** 数据库连接整个会话只开一次（op-sqlite 反复开关会显著增加延迟） */
function openOnce(): { driver: SqliteDriver; path: string } {
  if (!opened) {
    const handle = openFindrDb();
    migrate(handle.driver);
    opened = { driver: handle.driver, path: handle.path };
  }
  return opened;
}

export async function openRuntime(): Promise<RuntimeState> {
  const { driver, path } = openOnce();
  const [llmKey, asrKey] = await Promise.all([getApiKey('llm'), getApiKey('asr')]);
  return {
    driver,
    dbPath: path,
    llm: readLlmSettings(driver),
    asr: readAsrSettings(driver),
    capture: readCaptureSettings(driver),
    pipeline: readPipelineSettings(driver),
    llmKey,
    asrKey,
  };
}

/**
 * 图片分析开关的可用性：只有「能力已探测且明确不支持」且模型名没变时才锁死。
 * 没探测过一律按可用处理——需求 3.3 说的是「能力缺失时降级」，不是「未探测时禁用」。
 */
export function visionSupported(llm: LlmSettings | null): boolean {
  if (!llm?.capabilities) return true;
  if (capabilitiesStale(llm)) return true;
  return llm.capabilities.vision;
}

export function llmConfigured(llm: LlmSettings | null): boolean {
  return !!llm && !!llm.model && (llm.providerType !== 'openai-compat' || !!llm.baseUrl);
}

export type BuiltDeps = { ok: true; deps: AdvanceDeps } | { ok: false; error: string };

export function buildAdvanceDeps(rt: RuntimeState): BuiltDeps {
  if (!llmConfigured(rt.llm)) return { ok: false, error: '尚未配置主模型' };
  const llm = rt.llm!;
  return {
    ok: true,
    deps: {
      db: rt.driver,
      llm: makeLlmAdapter(llm),
      cfg: toProviderConfig(llm, rt.llmKey),
      media: deviceMediaIO,
      asr: rt.asr ? makeAsrAdapter(rt.asr, deviceMediaIO) : null,
      asrCfg: rt.asr ? toAsrProviderConfig(rt.asr, rt.asrKey) : null,
      visionSupported: visionSupported(llm),
      confirmThreshold: rt.pipeline.confirmThreshold,
      maxAnalyzeImages: rt.capture.maxAnalyzeImages,
    },
  };
}

/** 本次队列统一使用的图片分析开关 */
export function currentVision(rt: RuntimeState): boolean {
  return effectiveVision(rt.capture, visionSupported(rt.llm));
}

export async function runQueueNow(
  rt: RuntimeState,
  opts: { vision?: boolean } = {},
): Promise<QueueRunResult | { skipped: string }> {
  const built = buildAdvanceDeps(rt);
  if (!built.ok) return { skipped: built.error };
  return runQueue({ ...built.deps, vision: opts.vision ?? currentVision(rt) });
}

/** 单卡操作（编辑闭环）用：拿不到可用配置就直接抛，调用方负责提示 */
export function requireDeps(rt: RuntimeState): AdvanceDeps {
  const built = buildAdvanceDeps(rt);
  if (!built.ok) throw new Error(built.error);
  return built.deps;
}

/** L1 检索。core 的 searchCards 自带无网兜底，调用失败也能用原始 query 直查 */
export async function runSearch(rt: RuntimeState, query: string) {
  const built = buildAdvanceDeps(rt);
  if (!built.ok) throw new Error(built.error);
  return searchCards({ db: rt.driver, llm: built.deps.llm, cfg: built.deps.cfg }, query);
}

// ─────────────────────────────────────────────────────────────
// React 绑定
// ─────────────────────────────────────────────────────────────

export interface RuntimeValue {
  state: RuntimeState | null;
  error: string | null;
  /** 重新读一遍设置（保存设置后调用） */
  refresh: () => Promise<RuntimeState | null>;
}

const RuntimeContext = createContext<RuntimeValue | null>(null);

export function RuntimeProvider({ children }: PropsWithChildren) {
  const [state, setState] = useState<RuntimeState | null>(null);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      const next = await openRuntime();
      setState(next);
      setError(null);
      return next;
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      return null;
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const value = useMemo<RuntimeValue>(() => ({ state, error, refresh }), [state, error, refresh]);
  return <RuntimeContext.Provider value={value}>{children}</RuntimeContext.Provider>;
}

export function useRuntime(): RuntimeValue {
  const value = useContext(RuntimeContext);
  if (!value) throw new Error('useRuntime 必须在 RuntimeProvider 内使用');
  return value;
}

/** 拿到已初始化的运行时；未就绪时返回 null，调用方负责渲染加载态 */
export function useReadyRuntime(): { rt: RuntimeState; refresh: () => Promise<RuntimeState | null> } | null {
  const { state, refresh } = useRuntime();
  return state ? { rt: state, refresh } : null;
}
