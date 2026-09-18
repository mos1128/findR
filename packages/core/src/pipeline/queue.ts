import { listQueueCards, resetTranscriptRetries } from '../db/repository';
import { collectHotwords } from '../db/taxonomy';
import type { CardStatus } from '../types';
import { advanceCard, type AdvanceDeps } from './capture';

export interface QueueDeps extends AdvanceDeps {
  /** 本次队列统一使用的图片分析开关（录入时的选择会即时传递，恢复运行时用设置里的默认值） */
  vision?: boolean;
}

export interface QueueRunResult {
  /** 真正推进过（含失败重试计数）的卡片数 */
  processed: number;
  /** 变为 active 的卡片数，含待整理与纯图片卡片 */
  settled: number;
  failed: number;
  /** 因未配置 ASR 而原样跳过的卡片数 */
  skippedNoAsr: number;
  /** 上一次队列还没跑完，这次直接跳过 */
  alreadyRunning: boolean;
}

const BATCH = 5;
const MAX_PER_RUN = 50;

/**
 * 串行队列（并发 1）。触发点：录入完成、App 回前台、设置变更。
 *
 * 用模块级锁防重入：回前台与录入完成可能同一瞬间各触发一次，
 * 并发跑同一批卡会造成重复的模型调用与竞争写入。
 */
let running = false;

export async function runQueue(deps: QueueDeps, opts: { max?: number } = {}): Promise<QueueRunResult> {
  const empty: QueueRunResult = {
    processed: 0,
    settled: 0,
    failed: 0,
    skippedNoAsr: 0,
    alreadyRunning: true,
  };
  if (running) return empty;

  running = true;
  const now = deps.now ?? (() => new Date());
  const max = opts.max ?? MAX_PER_RUN;
  const result: QueueRunResult = {
    processed: 0,
    settled: 0,
    failed: 0,
    skippedNoAsr: 0,
    alreadyRunning: false,
  };

  // 没配 ASR 时待转写卡根本推不动，索性不选它们：
  // 否则一串这样的卡会堵在队头（按 created_at 升序），后面的卡永远轮不到。
  const asrReady = !!deps.asr && !!deps.asrCfg;
  const statuses: CardStatus[] = asrReady ? ['pending_transcript', 'pending'] : ['pending'];
  const attempted = new Set<string>();

  try {
    while (result.processed < max) {
      const batch = listQueueCards(deps.db, now(), BATCH, { statuses }).filter(
        (c) => !attempted.has(c.id),
      );
      if (batch.length === 0) break;

      let progressed = false;
      for (const card of batch) {
        attempted.add(card.id);
        const r = await advanceCard(deps, card.id, { vision: deps.vision });
        switch (r.outcome) {
          case 'activated':
          case 'plain-card':
          case 'needs-organize':
            result.processed++;
            result.settled++;
            progressed = true;
            break;
          case 'retry':
            result.processed++;
            result.failed++;
            progressed = true;
            break;
          case 'skipped-no-asr':
            // ASR 已配置却仍跳过，只可能是这张卡缺音频路径
            result.skippedNoAsr++;
            break;
          case 'skipped-not-pending':
            break;
        }
      }
      if (!progressed) break;
    }
  } finally {
    running = false;
  }
  return result;
}

/**
 * 批量补转写：无视退避与重试上限地 drain 所有 pending_transcript（需求 3.2）。
 * 热词取位置树一二级 + 高频实体，正好是转写最容易听错的两类词。
 */
export async function retryAllTranscriptions(
  deps: QueueDeps,
  opts: { max?: number } = {},
): Promise<QueueRunResult & { reset: number }> {
  const now = deps.now ?? (() => new Date());
  const reset = resetTranscriptRetries(deps.db, now());
  const hotwords = deps.hotwords ?? collectHotwords(deps.db);
  const run = await runQueue({ ...deps, hotwords }, opts);
  return { reset, ...run };
}

/** 仅供测试重置模块级锁 */
export function __resetQueueLock(): void {
  running = false;
}
