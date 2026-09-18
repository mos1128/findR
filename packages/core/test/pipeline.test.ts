import { expect, test } from 'vitest';
import {
  ensurePath,
  getCard,
  insertCard,
  listLocations,
  listQueueCards,
  MAX_AUTO_RETRY,
} from '../src/db/repository';
import { FakeLLMAdapter } from '../src/providers/fake';
import type { MediaIO } from '../src/providers/media';
import type {
  ASRProviderAdapter,
  ChatRequest,
  ProviderConfig,
  TranscribeRequest,
} from '../src/providers/types';
import { advanceCard, createDraft, ingestCapture, type AdvanceDeps } from '../src/pipeline/capture';
import { runQueue, retryAllTranscriptions, __resetQueueLock } from '../src/pipeline/queue';
import { regenerateDesc, reanalyzeCard, reorganizeCard, submitTranscript } from '../src/pipeline/edit';
import { makeCard, makeDb } from './helpers';

const CFG: ProviderConfig = { providerType: 'fake', model: 'fake' };
const NOW = new Date('2026-03-01T12:00:00.000Z');
const clock = () => NOW;

const stubMedia: MediaIO = {
  imageData: async (rel) => ({ base64: `b64:${rel}`, mime: 'image/webp' }),
  audioPart: async () => new Blob([new Uint8Array([0])]),
  fileUri: (rel) => `file:///docs/${rel}`,
  removeCardMedia: async () => undefined,
};

class FakeAsr implements ASRProviderAdapter {
  readonly requests: TranscribeRequest[] = [];
  private readonly queue: Array<{ text?: string; error?: string }>;
  constructor(responses: Array<{ text?: string; error?: string }> = []) {
    this.queue = [...responses];
  }
  async transcribe(req: TranscribeRequest): Promise<{ text: string }> {
    this.requests.push(req);
    const next = this.queue.shift();
    if (!next || next.error) throw new Error(next?.error ?? 'FakeAsr: 无预置响应');
    return { text: next.text ?? '' };
  }
}

function p1(over: Record<string, unknown> = {}): string {
  return JSON.stringify({
    structure_type: 'item',
    category: '物品存取',
    entity: '备用手电筒',
    aliases: ['手电'],
    path: null,
    path_matched: false,
    path_suggestion: '主卧衣柜顶层',
    steps: [],
    desc: '备用手电筒放在主卧衣柜顶层。',
    tags: ['应急'],
    confidence: 0.9,
    missing: [],
    ask: '',
    ...over,
  });
}

function deps(over: Partial<AdvanceDeps> & { llm: FakeLLMAdapter }): AdvanceDeps {
  return { db: over.db!, cfg: CFG, now: clock, media: stubMedia, ...over } as AdvanceDeps;
}

// ─────────────────────────────────────────────────────────────
// createDraft
// ─────────────────────────────────────────────────────────────

test('有音频且无文本才进待转写；打了字就直接进待解析', () => {
  const db = makeDb();
  createDraft({ db }, { source: 'voice', audio: 'files/audio/202603/a.m4a' }, { id: 'c1' });
  expect(getCard(db, 'c1')!.status).toBe('pending_transcript');

  // 边拍边说同时带了文字：文字即 transcript，不该再送去转写
  createDraft(
    { db },
    { source: 'voice', audio: 'files/audio/202603/b.m4a', text: '手电筒在衣柜' },
    { id: 'c2' },
  );
  expect(getCard(db, 'c2')!.status).toBe('pending');
  expect(getCard(db, 'c2')!.transcript).toBe('手电筒在衣柜');

  createDraft({ db }, { source: 'text', text: '纯文字' }, { id: 'c3' });
  expect(getCard(db, 'c3')!.status).toBe('pending');

  createDraft({ db }, { source: 'photo', images: ['files/cards/202603/d/01.webp'] }, { id: 'c4' });
  expect(getCard(db, 'c4')!.status).toBe('pending');
});

test('有图时 vision_analyzed 初值为「未分析」，无图为 null', () => {
  const db = makeDb();
  createDraft({ db }, { source: 'photo', images: ['a.webp', 'b.webp'] }, { id: 'c1' });
  expect(getCard(db, 'c1')!.visionAnalyzed).toBe(false);
  createDraft({ db }, { source: 'text', text: '无图' }, { id: 'c2' });
  expect(getCard(db, 'c2')!.visionAnalyzed).toBeNull();
});

// ─────────────────────────────────────────────────────────────
// 转写
// ─────────────────────────────────────────────────────────────

test('没有配置 ASR：卡片原样保留，重试计数不涨（这不是失败）', async () => {
  const db = makeDb();
  createDraft({ db }, { source: 'voice', audio: 'files/audio/202603/a.m4a' }, { id: 'c1' });
  const llm = new FakeLLMAdapter();

  const r = await advanceCard(deps({ db, llm }), 'c1');
  expect(r.outcome).toBe('skipped-no-asr');
  const card = getCard(db, 'c1')!;
  expect(card.status).toBe('pending_transcript');
  expect(card.retryCount).toBe(0);
  expect(card.audioPath).toBe('files/audio/202603/a.m4a');
  expect(llm.requests).toHaveLength(0);
});

test('转写成功后继续走理解，音频路径原样保留', async () => {
  const db = makeDb();
  createDraft({ db }, { source: 'voice', audio: 'files/audio/202603/a.m4a' }, { id: 'c1' });
  const llm = new FakeLLMAdapter([p1()]);
  const asr = new FakeAsr([{ text: '手电筒放主卧衣柜顶层了' }]);

  const r = await advanceCard(
    deps({ db, llm, asr, asrCfg: CFG, hotwords: ['主卧', '衣柜'] }),
    'c1',
  );
  expect(r.outcome).toBe('activated');
  const card = getCard(db, 'c1')!;
  expect(card.transcript).toBe('手电筒放主卧衣柜顶层了');
  expect(card.entity).toBe('备用手电筒');
  expect(card.audioPath).toBe('files/audio/202603/a.m4a');

  // ASR 走的是文件直传 + 热词
  expect(asr.requests[0].audio).toEqual({
    kind: 'file',
    rel: 'files/audio/202603/a.m4a',
    mime: 'audio/m4a',
  });
  expect(asr.requests[0].hotwords).toEqual(['主卧', '衣柜']);
});

test('转写失败：保持待转写，按退避序列排下次重试', async () => {
  const db = makeDb();
  createDraft({ db }, { source: 'voice', audio: 'files/audio/202603/a.m4a' }, { id: 'c1' });
  const llm = new FakeLLMAdapter();
  const asr = new FakeAsr([{ error: '网络超时' }]);

  const r = await advanceCard(deps({ db, llm, asr, asrCfg: CFG }), 'c1');
  expect(r.outcome).toBe('retry');
  const card = getCard(db, 'c1')!;
  expect(card.status).toBe('pending_transcript');
  expect(card.retryCount).toBe(1);
  expect(card.lastError).toContain('网络超时');
  // 第一次失败 → 1 分钟后
  expect(card.nextRetryAt).toBe(new Date(NOW.getTime() + 60_000).toISOString());
});

// ─────────────────────────────────────────────────────────────
// 图片分析开关
// ─────────────────────────────────────────────────────────────

test('图片分析关闭但有文字：不发图，且注入「用户主动关闭」的仅文本变体', async () => {
  const db = makeDb();
  createDraft(
    { db },
    { source: 'photo', text: '收据留底', images: ['files/cards/202603/c1/01.webp'] },
    { id: 'c1' },
  );
  const llm = new FakeLLMAdapter([p1({ confidence: 0.9 })]);

  await advanceCard(deps({ db, llm }), 'c1', { vision: false });

  const req = llm.requests[0] as ChatRequest;
  expect(req.parts.some((p) => p.type === 'image')).toBe(false);
  expect(req.system).toContain('本次用户选择不分析图片');
  // 用户已知情，不该在 desc 里声明「未见图片」
  expect(getCard(db, 'c1')!.visionAnalyzed).toBe(false);
});

test('模型不支持图片：走「能力缺失」变体而非「用户关闭」变体', async () => {
  const db = makeDb();
  createDraft(
    { db },
    { source: 'photo', text: '包装盒', images: ['files/cards/202603/c1/01.webp'] },
    { id: 'c1' },
  );
  const llm = new FakeLLMAdapter([p1()]);
  await advanceCard(deps({ db, llm, visionSupported: false }), 'c1', { vision: true });

  const req = llm.requests[0] as ChatRequest;
  expect(req.system).toContain('当前模型无法接收图片');
  expect(req.parts.some((p) => p.type === 'image')).toBe(false);
});

test('带图成功识别后 vision_analyzed 置 1，角标随之消失', async () => {
  const db = makeDb();
  createDraft(
    { db },
    { source: 'photo', text: '手电筒', images: ['files/cards/202603/c1/01.webp'] },
    { id: 'c1' },
  );
  const llm = new FakeLLMAdapter([p1()]);
  await advanceCard(deps({ db, llm }), 'c1', { vision: true });

  const req = llm.requests[0] as ChatRequest;
  const imagePart = req.parts.find((p) => p.type === 'image');
  expect(imagePart).toEqual({ type: 'image', mime: 'image/webp', base64: 'b64:files/cards/202603/c1/01.webp' });
  expect(getCard(db, 'c1')!.visionAnalyzed).toBe(true);
});

test('图片分析关闭且无文字：不调模型，直接落为纯图片卡片并强制确认', async () => {
  const db = makeDb();
  createDraft(
    { db },
    { source: 'photo', images: ['files/cards/202603/c1/01.webp'] },
    { id: 'c1' },
  );
  const llm = new FakeLLMAdapter();

  const r = await advanceCard(deps({ db, llm }), 'c1', { vision: false });
  expect(r.outcome).toBe('plain-card');
  expect(llm.requests).toHaveLength(0);

  const card = getCard(db, 'c1')!;
  expect(card.status).toBe('active');
  expect(card.desc).toBeNull();
  expect(card.needsConfirm).toBe(true);
  expect(card.visionAnalyzed).toBe(false);
  expect(card.images).toHaveLength(1);
});

test('单卡图片超过上限时只送前 N 张', async () => {
  const db = makeDb();
  const images = Array.from({ length: 9 }, (_, i) => `files/cards/202603/c1/0${i + 1}.webp`);
  createDraft({ db }, { source: 'photo', text: '流程截图', images }, { id: 'c1' });
  const llm = new FakeLLMAdapter([p1({ structure_type: 'procedure', category: '流程备忘' })]);

  await advanceCard(deps({ db, llm, maxAnalyzeImages: 3 }), 'c1', { vision: true });
  const sent = (llm.requests[0] as ChatRequest).parts.filter((p) => p.type === 'image');
  expect(sent).toHaveLength(3);
});

// ─────────────────────────────────────────────────────────────
// 解析结果落库
// ─────────────────────────────────────────────────────────────

test('低置信度、分类选不出、item 缺位置都触发待确认', async () => {
  const db = makeDb();

  createDraft({ db }, { source: 'text', text: 'a' }, { id: 'low' });
  await advanceCard(deps({ db, llm: new FakeLLMAdapter([p1({ confidence: 0.3 })]) }), 'low');
  expect(getCard(db, 'low')!.needsConfirm).toBe(true);

  createDraft({ db }, { source: 'text', text: 'b' }, { id: 'nocat' });
  await advanceCard(deps({ db, llm: new FakeLLMAdapter([p1({ category: null })]) }), 'nocat');
  expect(getCard(db, 'nocat')!.needsConfirm).toBe(true);

  createDraft({ db }, { source: 'text', text: 'c' }, { id: 'nopath' });
  await advanceCard(deps({ db, llm: new FakeLLMAdapter([p1({ path: null })]) }), 'nopath');
  expect(getCard(db, 'nopath')!.needsConfirm).toBe(true);
});

test('待办与流程类不追问位置，path 恒为 null', async () => {
  const db = makeDb();
  createDraft({ db }, { source: 'text', text: '该买猫砂了' }, { id: 'c1' });
  const llm = new FakeLLMAdapter([
    p1({ structure_type: 'todo', category: '待买补货', path: null, path_matched: false, ask: '' }),
  ]);
  await advanceCard(deps({ db, llm }), 'c1');

  const card = getCard(db, 'c1')!;
  expect(card.structureType).toBe('todo');
  expect(card.pathIds).toBeNull();
  expect(card.ask).toBeNull();
});

test('ask 与 path_suggestion 会落库，供记忆流展示补问入口', async () => {
  const db = makeDb();
  createDraft({ db }, { source: 'text', text: '扳手放工具箱了' }, { id: 'c1' });
  const llm = new FakeLLMAdapter([
    p1({ path: null, path_matched: false, path_suggestion: '阳台/工具箱', ask: '工具箱在哪个房间？' }),
  ]);
  await advanceCard(deps({ db, llm }), 'c1');

  const card = getCard(db, 'c1')!;
  expect(card.ask).toBe('工具箱在哪个房间？');
  expect(card.pathSuggestion).toBe('阳台/工具箱');
  expect(card.pathMatched).toBe(false);
});

test('解析两次都失败 → 待整理，原文与图片都留着且仍带未分析角标', async () => {
  const db = makeDb();
  createDraft(
    { db },
    { source: 'photo', text: '一段口述', images: ['files/cards/202603/c1/01.webp'] },
    { id: 'c1' },
  );
  const llm = new FakeLLMAdapter(['不是 JSON', '仍然不是 JSON']);

  const r = await advanceCard(deps({ db, llm }), 'c1', { vision: true });
  expect(r.outcome).toBe('needs-organize');

  const card = getCard(db, 'c1')!;
  expect(card.status).toBe('active');
  expect(card.needsOrganize).toBe(true);
  expect(card.transcript).toBe('一段口述');
  expect(card.images).toHaveLength(1);
  expect(card.desc).toBeNull();
  // 图没被成功分析过，角标必须还在
  expect(card.visionAnalyzed).toBe(false);
});

test('模型调用失败 → 草稿保持待解析并按退避排重试', async () => {
  const db = makeDb();
  createDraft({ db }, { source: 'text', text: 'x' }, { id: 'c1' });
  const r = await advanceCard(deps({ db, llm: new FakeLLMAdapter() }), 'c1');

  expect(r.outcome).toBe('retry');
  const card = getCard(db, 'c1')!;
  expect(card.status).toBe('pending');
  expect(card.retryCount).toBe(1);
  expect(card.nextRetryAt).toBe(new Date(NOW.getTime() + 60_000).toISOString());
});

test('已入库的卡片不会被 advanceCard 再处理', async () => {
  const db = makeDb();
  insertCard(db, makeCard({ id: 'c1', status: 'active' }));
  const llm = new FakeLLMAdapter([p1()]);
  const r = await advanceCard(deps({ db, llm }), 'c1');
  expect(r.outcome).toBe('skipped-not-pending');
  expect(llm.requests).toHaveLength(0);
});

// ─────────────────────────────────────────────────────────────
// 队列
// ─────────────────────────────────────────────────────────────

test('队列串行推进多张草稿', async () => {
  __resetQueueLock();
  const db = makeDb();
  createDraft({ db }, { source: 'text', text: 'a' }, { id: 'c1' });
  createDraft({ db }, { source: 'text', text: 'b' }, { id: 'c2' });
  createDraft({ db }, { source: 'text', text: 'c' }, { id: 'c3' });
  const llm = new FakeLLMAdapter([p1(), p1(), p1()]);

  const r = await runQueue(deps({ db, llm }));
  expect(r.processed).toBe(3);
  expect(r.settled).toBe(3);
  expect(listQueueCards(db, NOW)).toHaveLength(0);
});

test('没配 ASR 时待转写卡不入选，不会堵住后面的卡', async () => {
  __resetQueueLock();
  const db = makeDb();
  // 6 张待转写卡超过单批 5 张：若它们入选就会占满队头，后面的卡永远轮不到
  for (let i = 0; i < 6; i++) {
    createDraft({ db }, { source: 'voice', audio: `files/audio/202603/v${i}.m4a` }, { id: `v${i}` });
  }
  createDraft({ db }, { source: 'text', text: '文字卡' }, { id: 'text' });
  const llm = new FakeLLMAdapter([p1()]);

  const r = await runQueue(deps({ db, llm }));
  expect(r.settled).toBe(1);
  expect(r.skippedNoAsr).toBe(0);
  expect(getCard(db, 'text')!.status).toBe('active');
  expect(getCard(db, 'v0')!.status).toBe('pending_transcript');
  // 没有被无谓地计入重试，素材原样等待
  expect(getCard(db, 'v0')!.retryCount).toBe(0);
});

test('配好 ASR 后队列会把积压的待转写卡一起补完', async () => {
  __resetQueueLock();
  const db = makeDb();
  createDraft({ db }, { source: 'voice', audio: 'files/audio/202603/v0.m4a' }, { id: 'v0' });
  createDraft({ db }, { source: 'voice', audio: 'files/audio/202603/v1.m4a' }, { id: 'v1' });
  const llm = new FakeLLMAdapter([p1(), p1()]);
  const asr = new FakeAsr([{ text: '第一段' }, { text: '第二段' }]);

  const r = await runQueue(deps({ db, llm, asr, asrCfg: CFG }));
  expect(r.settled).toBe(2);
  expect(getCard(db, 'v0')!.status).toBe('active');
  expect(getCard(db, 'v1')!.status).toBe('active');
});

test('队列不会把已达重试上限的卡片再捞起来', async () => {
  __resetQueueLock();
  const db = makeDb();
  insertCard(db, makeCard({ id: 'c1', status: 'pending', retryCount: MAX_AUTO_RETRY }));
  const llm = new FakeLLMAdapter([p1()]);
  const r = await runQueue(deps({ db, llm }));
  expect(r.processed).toBe(0);
  expect(llm.requests).toHaveLength(0);
});

test('批量补转写：重置退避与上限、带上热词', async () => {
  __resetQueueLock();
  const db = makeDb();
  insertCard(
    db,
    makeCard({
      id: 'c1',
      status: 'pending_transcript',
      audioPath: 'files/audio/202603/a.m4a',
      retryCount: MAX_AUTO_RETRY,
      nextRetryAt: '2026-04-01T00:00:00.000Z',
    }),
  );
  const llm = new FakeLLMAdapter([p1()]);
  const asr = new FakeAsr([{ text: '手电筒在衣柜' }]);

  const r = await retryAllTranscriptions(deps({ db, llm, asr, asrCfg: CFG }));
  expect(r.reset).toBe(1);
  expect(r.settled).toBe(1);
  expect(getCard(db, 'c1')!.status).toBe('active');
  // 没显式给热词时自动从位置树与高频实体收集
  expect(asr.requests).toHaveLength(1);
});

// ─────────────────────────────────────────────────────────────
// 编辑闭环
// ─────────────────────────────────────────────────────────────

test('补文字把待转写推进到入库', async () => {
  const db = makeDb();
  createDraft({ db }, { source: 'voice', audio: 'files/audio/202603/a.m4a' }, { id: 'c1' });
  const llm = new FakeLLMAdapter([p1()]);

  const r = await submitTranscript(deps({ db, llm }), 'c1', '手电筒放衣柜了');
  expect(r.outcome).toBe('activated');
  const card = getCard(db, 'c1')!;
  expect(card.transcript).toBe('手电筒放衣柜了');
  expect(card.status).toBe('active');
});

test('重新整理成功后清掉待整理标志', async () => {
  const db = makeDb();
  insertCard(
    db,
    makeCard({ id: 'c1', status: 'active', needsOrganize: true, transcript: '口述原文' }),
  );
  const llm = new FakeLLMAdapter([p1()]);

  const r = await reorganizeCard(deps({ db, llm }), 'c1');
  expect(r.outcome).toBe('activated');
  expect(getCard(db, 'c1')!.needsOrganize).toBe(false);
  expect(getCard(db, 'c1')!.entity).toBe('备用手电筒');
});

test('重新整理再次失败时待整理标志保持不动（不能只清标志留下空卡）', async () => {
  const db = makeDb();
  insertCard(
    db,
    makeCard({ id: 'c1', status: 'active', needsOrganize: true, transcript: '口述原文' }),
  );
  const r = await reorganizeCard(deps({ db, llm: new FakeLLMAdapter(['坏输出', '还是坏输出']) }), 'c1');
  expect(r.outcome).toBe('needs-organize');
  expect(getCard(db, 'c1')!.needsOrganize).toBe(true);
});

test('补分析图片：重跑视觉理解并清掉未分析角标', async () => {
  const db = makeDb();
  insertCard(
    db,
    makeCard({
      id: 'c1',
      status: 'active',
      needsConfirm: false,
      images: ['files/cards/202603/c1/01.webp'],
      visionAnalyzed: false,
      transcript: null,
    }),
  );
  const llm = new FakeLLMAdapter([p1({ desc: '补分析后的描述' })]);

  const r = await reanalyzeCard(deps({ db, llm }), 'c1');
  expect(r.outcome).toBe('activated');
  const card = getCard(db, 'c1')!;
  expect(card.visionAnalyzed).toBe(true);
  expect(card.desc).toBe('补分析后的描述');
  expect((llm.requests[0] as ChatRequest).parts.some((p) => p.type === 'image')).toBe(true);
});

test('补分析失败时卡片保持原样，不被降级成草稿', async () => {
  const db = makeDb();
  insertCard(
    db,
    makeCard({
      id: 'c1',
      status: 'active',
      entity: '原有实体',
      desc: '原有描述',
      images: ['files/cards/202603/c1/01.webp'],
      visionAnalyzed: false,
    }),
  );
  const r = await reanalyzeCard(deps({ db, llm: new FakeLLMAdapter() }), 'c1');

  expect(r.outcome).toBe('retry');
  const card = getCard(db, 'c1')!;
  expect(card.status).toBe('active');
  expect(card.entity).toBe('原有实体');
  expect(card.desc).toBe('原有描述');
  expect(card.visionAnalyzed).toBe(false);
});

test('重新生成 desc 只改 desc，用户编辑过的字段不被模型覆盖', async () => {
  const db = makeDb();
  insertCard(
    db,
    makeCard({
      id: 'c1',
      status: 'active',
      entity: '用户改过的名字',
      categoryId: 'cat_procedure',
      structureType: 'procedure',
      transcript: '一段口述',
      desc: '旧描述',
    }),
  );
  const llm = new FakeLLMAdapter([
    p1({ entity: '模型想改的名字', category: '物品存取', structure_type: 'item', desc: '新描述' }),
  ]);

  const r = await regenerateDesc(deps({ db, llm }), 'c1');
  expect(r.ok).toBe(true);

  const card = getCard(db, 'c1')!;
  expect(card.desc).toBe('新描述');
  expect(card.entity).toBe('用户改过的名字');
  expect(card.structureType).toBe('procedure');
  expect(card.categoryId).toBe('cat_procedure');

  // 是纯文本调用，不带图
  const req = llm.requests[0] as ChatRequest;
  expect(req.parts.some((p) => p.type === 'image')).toBe(false);
  // 且把已确认字段作为既定事实注入了
  expect(JSON.stringify(req.parts)).toContain('用户改过的名字');
});

test('重新生成 desc 失败时不改动卡片', async () => {
  const db = makeDb();
  insertCard(db, makeCard({ id: 'c1', status: 'active', desc: '旧描述' }));
  const r = await regenerateDesc(deps({ db, llm: new FakeLLMAdapter(['垃圾输出']) }), 'c1');
  expect(r.ok).toBe(false);
  expect(getCard(db, 'c1')!.desc).toBe('旧描述');
});

// ─────────────────────────────────────────────────────────────
// 端到端
// ─────────────────────────────────────────────────────────────

test('ingestCapture 一次走完落盘后的全流程', async () => {
  const db = makeDb();
  const llm = new FakeLLMAdapter([p1()]);
  const card = await ingestCapture(
    deps({ db, llm, idGen: () => 'fixed-id' }),
    { source: 'text', text: '手电筒放衣柜' },
  );
  expect(card.id).toBe('fixed-id');
  expect(card.status).toBe('active');
});

// ─────────────────────────────────────────────────────────────
// 位置树增量维护（问题：不该要求用户先去手工建位置）
// ─────────────────────────────────────────────────────────────

test('解析出的位置自动建树：新建了层级就要用户确认一次', async () => {
  const db = makeDb();
  const llm = new FakeLLMAdapter([p1({ path: ['主卧', '衣柜'], confidence: 0.9 })]);
  const card = await ingestCapture(deps({ db, llm }), {
    source: 'text',
    text: '手电筒放主卧衣柜',
  });

  expect(card.pathNames).toBe('主卧/衣柜');
  expect(card.pathMatched).toBe(false); // 有新建 ⇒ 没命中已有树
  expect(card.needsConfirm).toBe(true); // 新位置对不对，让用户过一眼
  expect(listLocations(db).map((l) => l.name).sort()).toEqual(['主卧', '衣柜']);
});

test('位置已存在时复用，不再要求用户确认', async () => {
  const db = makeDb();
  // 上次已经长出来的树
  ensurePath(db, ['主卧', '衣柜']);

  const llm = new FakeLLMAdapter([p1({ path: ['主卧', '衣柜'], confidence: 0.9 })]);
  const card = await ingestCapture(deps({ db, llm }), {
    source: 'text',
    text: '手电筒放主卧衣柜',
  });

  expect(card.pathMatched).toBe(true);
  expect(card.needsConfirm).toBe(false);
  expect(listLocations(db)).toHaveLength(2); // 没有因为重复解析又长出一套
});
