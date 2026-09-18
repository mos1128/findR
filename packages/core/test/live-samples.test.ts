import { describe, expect, test } from 'vitest';
import { ingestCapture } from '../src/pipeline/capture';
import { searchCards } from '../src/search/service';
import { AnthropicAdapter } from '../src/providers/anthropic';
import { listCategories, upsertLocation } from '../src/db/repository';
import type { ProviderConfig } from '../src/providers/types';
import { SAMPLES, type Sample } from './fixtures/samples';
import { makeDb } from './helpers';

/**
 * 20 条样本 × 真模型：把《测试计划.md》第三节的指标实际跑出来。
 *
 * 默认跳过；需要本地网关在跑：
 *   $env:FINDR_BASE_URL='http://127.0.0.1:7788'; $env:FINDR_API_KEY='ccg-gateway'; $env:FINDR_MODEL='claude-opus-5'
 *   pnpm vitest run test/live-samples.test.ts
 * 只跑某一条：再加 $env:FINDR_SAMPLE='s03'
 *
 * **已知局限**：node 侧没有相机，样本里的 `imageCount` 只是记录用途，跑的时候一律当纯文本送。
 * 因此「只有照片」「只拍特写」这两类样本在这里**测不到视觉理解**，那部分只能在真机上验。
 * 报告里会把它们标成 `vision-only`，并从需要图片的指标里排除。
 */

const BASE = process.env.FINDR_BASE_URL;
const KEY = process.env.FINDR_API_KEY;
const MODEL = process.env.FINDR_MODEL;
const ONLY = process.env.FINDR_SAMPLE;
const live = !!BASE && !!KEY && !!MODEL;

const CFG: ProviderConfig = {
  providerType: 'anthropic',
  baseUrl: BASE,
  model: MODEL ?? '',
  apiKey: KEY,
  authStyle: 'bearer',
  userAgent: 'claude-cli/2.1.268 (external, cli)',
};

/** 位置树按《场景分析.md》的常见房间预置，让 path 命中率有意义 */
function seedLocations(db: ReturnType<typeof makeDb>): void {
  const tree: Array<[string, string | null, string]> = [
    ['l_master', null, '主卧'],
    ['l_wardrobe', 'l_master', '衣柜'],
    ['l_box', 'l_wardrobe', '纸箱'],
    ['l_study', null, '书房'],
    ['l_drawer', 'l_study', '抽屉'],
    ['l_balcony', null, '阳台'],
    ['l_cabinet', 'l_balcony', '储物柜'],
    ['l_storage', null, '储藏间'],
    ['l_entry', null, '玄关'],
    ['l_shoecab', 'l_entry', '鞋柜'],
    ['l_kitchen', null, '厨房'],
    ['l_toolbox', 'l_balcony', '工具箱'],
  ];
  tree.forEach(([id, parentId, name], i) => {
    upsertLocation(db, { id, parentId, name, sort: i });
  });
}

interface Row {
  id: string;
  bad: string;
  outcome: string;
  ms: number;
  structureType: string | null;
  typeOk: boolean;
  category: string | null;
  categoryOk: boolean;
  pathMatched: boolean | null;
  askFired: boolean;
  recalled: boolean | null;
  visionOnly: boolean;
  error?: string;
}

describe.skipIf(!live)('20 条样本 · 真模型指标', () => {
  test('跑完整测试集并输出报告', async () => {
    const db = makeDb();
    seedLocations(db);
    const llm = new AnthropicAdapter();
    const samples: Sample[] = ONLY ? SAMPLES.filter((s) => s.id === ONLY) : [...SAMPLES];

    const rows: Row[] = [];
    for (const sample of samples) {
      const started = Date.now();
      // 纯文本路径：口述即 transcript；图片样本在 node 侧送不出去，按 vision-only 标注
      const visionOnly = sample.imageCount > 0 && sample.transcript.trim().length === 0;

      const card = await ingestCapture(
        { db, llm, cfg: CFG },
        {
          source: sample.imageCount > 0 ? 'photo' : 'text',
          text: sample.transcript.trim() || null,
          images: null,
          audio: null,
        },
        { vision: sample.vision && !visionOnly },
      );
      const ms = Date.now() - started;
      const categoryName = card.categoryId
        ? (listCategories(db).find((c) => c.id === card.categoryId)?.name ?? null)
        : null;

      // 检索召回：用样本自带的问句跑 L1，看主卡是否进 top-5
      let recalled: boolean | null = null;
      if (card.status === 'active' && sample.expectation.shouldHit) {
        try {
          const res = await searchCards({ db, llm, cfg: CFG }, sample.query);
          recalled = res.cards.slice(0, 5).some((c) => c.id === card.id);
        } catch {
          recalled = null;
        }
      }

      rows.push({
        id: sample.id,
        bad: sample.bad,
        outcome: card.status === 'active' && !card.needsOrganize ? 'ok' : (card.lastError ?? card.status),
        ms,
        structureType: card.structureType,
        typeOk: sample.expectation.structureType
          ? card.structureType === sample.expectation.structureType
          : true,
        category: categoryName,
        categoryOk: sample.expectation.category
          ? categoryName === sample.expectation.category
          : true,
        pathMatched: card.pathMatched,
        askFired: !!card.ask,
        recalled,
        visionOnly,
        error: card.lastError ?? undefined,
      });

      const flag = visionOnly ? '👁 ' : rows.at(-1)!.typeOk ? '  ' : '✗ ';
      console.log(
        `${flag}${sample.id} [${sample.bad}] ${ms}ms ${card.structureType ?? '-'} ` +
          `${card.entity ?? '(无实体)'} ${card.needsOrganize ? '待整理' : ''}`,
      );
    }

    // ── 指标 ────────────────────────────────────────────────
    const textRunnable = rows.filter((r) => !r.visionOnly);
    const parsed = textRunnable.filter((r) => r.outcome === 'ok').length;
    const parseRate = textRunnable.length > 0 ? parsed / textRunnable.length : 0;

    const typeChecked = textRunnable.filter((r) => r.structureType !== null);
    const typeRate =
      typeChecked.length > 0 ? typeChecked.filter((r) => r.typeOk).length / typeChecked.length : 0;

    const askRate =
      textRunnable.length > 0 ? textRunnable.filter((r) => r.askFired).length / textRunnable.length : 0;

    const pathChecked = textRunnable.filter((r) => r.pathMatched !== null);
    const pathRate =
      pathChecked.length > 0
        ? pathChecked.filter((r) => r.pathMatched === true).length / pathChecked.length
        : 0;

    const recallChecked = textRunnable.filter((r) => r.recalled !== null);
    const recallRate =
      recallChecked.length > 0
        ? recallChecked.filter((r) => r.recalled === true).length / recallChecked.length
        : 0;

    const latencies = textRunnable.map((r) => r.ms).sort((a, b) => a - b);
    const p95 = latencies.length > 0 ? latencies[Math.floor(latencies.length * 0.95)] : 0;

    const pct = (n: number) => `${(n * 100).toFixed(1)}%`;
    console.log('\n──────── 指标（已排除只能真机跑的视觉样本）────────');
    console.log(`样本总数            ${rows.length}（其中 vision-only ${rows.length - textRunnable.length}）`);
    console.log(`JSON 可解析率        ${pct(parseRate)}   目标 ≥ 98%`);
    console.log(`结构类型准确率       ${pct(typeRate)}`);
    console.log(`path 命中率          ${pct(pathRate)}   目标 ≥ 80%（样本 ${pathChecked.length} 条）`);
    console.log(`ask 触发率           ${pct(askRate)}   目标 10% ~ 25%`);
    console.log(`L1 top-5 召回率      ${pct(recallRate)}   目标 ≥ 85%（样本 ${recallChecked.length} 条）`);
    console.log(`P1 延迟 P95          ${p95}ms\n`);

    // 只对硬指标断言，其余留作调优参考
    expect(parseRate).toBeGreaterThanOrEqual(0.98);
  }, 30 * 60_000);
});
