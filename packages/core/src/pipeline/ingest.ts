import type { MemoryCard } from '../types';
import { ingestCapture, type AdvanceDeps } from './capture';

/**
 * M0 的纯文本录入入口，保留为簿封装以维持既有调用方与测试不变。
 * 新代码请直接用 createDraft + advanceCard（界面要先把草稿渲染出来）。
 */
export async function ingestText(
  deps: AdvanceDeps,
  input: { transcript: string },
): Promise<MemoryCard> {
  return ingestCapture(deps, { source: 'text', text: input.transcript });
}

export type { AdvanceDeps, AdvanceResult, AdvanceOutcome, CaptureInput } from './capture';
