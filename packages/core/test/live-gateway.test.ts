import { expect, test } from 'vitest';
import { upsertLocation } from '../src/db/repository';
import { ingestText } from '../src/pipeline/ingest';
import { AnthropicAdapter } from '../src/providers/anthropic';
import type { ProviderConfig } from '../src/providers/types';
import { searchCards } from '../src/search/service';
import { makeDb } from './helpers';

// 真实网关冒烟（默认跳过）：
//   $env:FINDR_BASE_URL='http://127.0.0.1:7788'; $env:FINDR_API_KEY='…'; $env:FINDR_MODEL='claude-opus-5'
//   pnpm vitest run test/live-gateway.test.ts
const BASE = process.env.FINDR_BASE_URL;
const KEY = process.env.FINDR_API_KEY;
const MODEL = process.env.FINDR_MODEL;
const live = Boolean(BASE && KEY && MODEL);

const CFG: ProviderConfig = {
  providerType: 'anthropic',
  baseUrl: BASE,
  model: MODEL ?? '',
  apiKey: KEY,
  userAgent: 'claude-cli/2.1.268 (external, cli)',
};

test.skipIf(!live)('真实网关冒烟：P1 录入 + P2 检索', async () => {
  const db = makeDb();
  upsertLocation(db, { id: 'loc_master', parentId: null, name: '主卧', sort: 0 });
  upsertLocation(db, { id: 'loc_wardrobe', parentId: 'loc_master', name: '衣柜', sort: 0 });
  const llm = new AnthropicAdapter();

  const t0 = Date.now();
  const card = await ingestText(
    { db, llm, cfg: CFG },
    { transcript: '备用手电筒放主卧衣柜最下面的纸箱里了，黑色塑料壳，装两节五号电池' },
  );
  console.log('\n[P1] 耗时 %dms', Date.now() - t0);
  console.log(
    JSON.stringify(
      {
        status: card.status,
        category: card.categoryId,
        entity: card.entity,
        path: card.pathNames,
        pathMatched: card.pathMatched,
        tags: card.tags,
        confidence: card.confidence,
        needsConfirm: card.needsConfirm,
        needsOrganize: card.needsOrganize,
        lastError: card.lastError,
        desc: card.desc,
      },
      null,
      2,
    ),
  );
  expect(card.status).toBe('active');
  expect(card.needsOrganize).toBe(false);
  expect(card.entity).toBeTruthy();
  expect(card.desc).toBeTruthy();

  const t1 = Date.now();
  const res = await searchCards({ db, llm, cfg: CFG }, '手电筒放哪了？');
  console.log('\n[P2] 耗时 %dms', Date.now() - t1);
  console.log(JSON.stringify(res.p2, null, 2));
  console.log(
    '[命中]',
    res.cards.map((c) => ({ entity: c.entity, path: c.pathNames, desc: c.desc?.slice(0, 60) })),
  );
  expect(res.usedFallback).toBe(false);
  expect(res.cards.length).toBeGreaterThanOrEqual(1);
}, 180_000);
