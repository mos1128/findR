/// 串行重试队列 —— 逐字对应 `packages/core/src/pipeline/queue.ts`（119 行）。
///
/// 触发点：录入完成、App 回前台、设置变更。
/// 用**模块级锁**防重入：回前台与录入完成可能同一瞬间各触发一次，
/// 并发跑同一批卡会造成重复的模型调用与竞争写入。
///
/// ⚠️ **Dart 侧偏离 TS 的一处**：TS 的 `QueueDeps extends AdvanceDeps`（再加一个 `vision`），
/// Dart 没有结构化子类型，硬造一个包装类会让每个调用点都多一层解包。
/// 这里把那个字段提成 [runQueue] 的具名参数 —— 语义完全一样，调用点更短。
/// 而 TS 里 `retryAllTranscriptions` 的 `{...deps, hotwords}` 由
/// [AdvanceDeps.withHotwords] 承担（与 `P2Output.withSynonyms` 同一个套路）。
///
/// 模块级状态就是库级变量 `_running`。`dart test` 每个测试文件跑在独立 isolate 里，
/// 所以跨文件不互相干扰；**同一文件内**的用例之间会，因此留了 [resetQueueLockForTest]。
library;

import '../db/repository.dart';
import '../db/taxonomy.dart';
import '../types.dart';
import 'capture.dart';

final class QueueRunResult {
  const QueueRunResult({
    required this.processed,
    required this.settled,
    required this.failed,
    required this.skippedNoAsr,
    required this.alreadyRunning,
  });

  /// 真正推进过（含失败重试计数）的卡片数。
  final int processed;

  /// 变为 active 的卡片数，含待整理与纯图片卡片。
  final int settled;

  final int failed;

  /// 因未配置 ASR 而原样跳过的卡片数。
  final int skippedNoAsr;

  /// 上一次队列还没跑完，这次直接跳过。
  final bool alreadyRunning;
}

const int _batch = 5;
const int _maxPerRun = 50;

bool _running = false;

/// 仅供测试重置模块级锁（对应 TS 的 `__resetQueueLock`）。
void resetQueueLockForTest() => _running = false;

/// 跑一轮队列。
///
/// [vision] 是本次队列统一使用的图片分析开关
///（录入时的选择会即时传递，恢复运行时用设置里的默认值）。
Future<QueueRunResult> runQueue(AdvanceDeps deps, {bool? vision, int? max}) async {
  const empty = QueueRunResult(
    processed: 0,
    settled: 0,
    failed: 0,
    skippedNoAsr: 0,
    alreadyRunning: true,
  );
  if (_running) return empty;

  _running = true;
  final clock = deps.clock;
  final limit = max ?? _maxPerRun;
  var processed = 0;
  var settled = 0;
  var failed = 0;
  var skippedNoAsr = 0;

  // 没配 ASR 时待转写卡根本推不动，索性不选它们：
  // 否则一串这样的卡会堵在队头（按 created_at 升序），后面的卡永远轮不到。
  final asrReady = deps.asr != null && deps.asrCfg != null;
  final statuses = asrReady
      ? const <CardStatus>[CardStatus.pendingTranscript, CardStatus.pending]
      : const <CardStatus>[CardStatus.pending];
  final attempted = <String>{};

  try {
    while (processed < limit) {
      final batch = listQueueCards(
        deps.db,
        clock(),
        limit: _batch,
        opts: QueueQueryOptions(statuses: statuses),
      ).where((c) => !attempted.contains(c.id)).toList();
      if (batch.isEmpty) break;

      var progressed = false;
      for (final card in batch) {
        attempted.add(card.id);
        final r = await advanceCard(deps, card.id, vision: vision);
        switch (r.outcome) {
          case AdvanceOutcome.activated:
          case AdvanceOutcome.plainCard:
          case AdvanceOutcome.needsOrganize:
            processed++;
            settled++;
            progressed = true;
          case AdvanceOutcome.retry:
            processed++;
            failed++;
            progressed = true;
          case AdvanceOutcome.skippedNoAsr:
            // ASR 已配置却仍跳过，只可能是这张卡缺音频路径
            skippedNoAsr++;
          case AdvanceOutcome.skippedNotPending:
            break;
        }
      }
      if (!progressed) break;
    }
  } finally {
    _running = false;
  }

  return QueueRunResult(
    processed: processed,
    settled: settled,
    failed: failed,
    skippedNoAsr: skippedNoAsr,
    alreadyRunning: false,
  );
}

/// 批量补转写：**无视退避与重试上限**地 drain 所有 `pending_transcript`（需求 3.2）。
/// 热词取位置树一二级 + 高频实体，正好是转写最容易听错的两类词。
Future<({int reset, QueueRunResult run})> retryAllTranscriptions(
  AdvanceDeps deps, {
  int? max,
}) async {
  final reset = resetTranscriptRetries(deps.db, deps.clock());
  final hotwords = deps.hotwords ?? collectHotwords(deps.db);
  final run = await runQueue(deps.withHotwords(hotwords), max: max);
  return (reset: reset, run: run);
}
