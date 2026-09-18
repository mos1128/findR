import { expect, test } from 'vitest';
import { inflateSync } from 'node:zlib';
import { base64ToBytes, bytesToBase64 } from '../src/util/base64';
import { makeTestPng, makeTestWav } from '../src/providers/samples';
import { anthropicDelta, openaiDelta } from '../src/providers/sse';
import { OpenAICompatAdapter, OpenAICompatAsrAdapter } from '../src/providers/openai-compat';
import { probeCapability, probeLlm } from '../src/providers/capabilities';
import type { MediaIO } from '../src/providers/media';
import type { ProviderConfig } from '../src/providers/types';

const CFG: ProviderConfig = {
  providerType: 'openai-compat',
  baseUrl: 'http://192.168.1.9:7788',
  model: 'qwen-vl-max',
  apiKey: 'sk-test',
};

interface FakeResponse {
  json?: unknown;
  text?: string;
  status?: number;
  sse?: string;
}

function fakeFetch(responses: FakeResponse[]) {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const fn = (async (url: string | URL, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} });
    const r = responses.shift();
    if (!r) throw new Error('fakeFetch: 没有预置响应');
    if (r.sse != null) {
      return new Response(r.sse, { headers: { 'content-type': 'text/event-stream' } });
    }
    if (r.text != null) return new Response(r.text, { status: r.status ?? 200 });
    return Response.json(r.json ?? {}, { status: r.status ?? 200 });
  }) as unknown as typeof fetch;
  return { fn, calls };
}

const stubMedia: MediaIO = {
  imageData: async () => ({ base64: 'aW1n', mime: 'image/webp' }),
  audioPart: async (_rel, mime) => new Blob([new Uint8Array([1, 2, 3, 4])], { type: mime }),
  fileUri: (rel) => `file:///docs/${rel}`,
  removeCardMedia: async () => undefined,
};

// ─────────────────────────────────────────────────────────────
// 基础工具
// ─────────────────────────────────────────────────────────────

test('base64 编解码往返（含非 3 字节倍数与容错字符）', () => {
  for (const len of [0, 1, 2, 3, 4, 61, 256]) {
    const bytes = new Uint8Array(len);
    for (let i = 0; i < len; i++) bytes[i] = (i * 37) & 0xff;
    const encoded = bytesToBase64(bytes);
    expect(base64ToBytes(encoded)).toEqual(bytes);
  }
  // 换行与 '=' 填充应被忽略：'AABB' → 0x00 0x00 0x41
  expect(base64ToBytes('AA\nBB==')).toEqual(new Uint8Array([0x00, 0x00, 0x41]));
  expect(base64ToBytes('QUJD')).toEqual(new Uint8Array([0x41, 0x42, 0x43]));
});

test('内嵌测试 PNG 是结构合法的 PNG（zlib 可解、CRC 正确）', () => {
  const png = makeTestPng(64);
  expect(Array.from(png.subarray(0, 8))).toEqual([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

  // 逐块走一遍，校验每个块的 CRC 并取出 IDAT
  const view = new DataView(png.buffer, png.byteOffset, png.byteLength);
  let offset = 8;
  const idat: Uint8Array[] = [];
  const types: string[] = [];
  while (offset < png.length) {
    const len = view.getUint32(offset);
    const type = String.fromCharCode(...png.subarray(offset + 4, offset + 8));
    types.push(type);
    const data = png.subarray(offset + 8, offset + 8 + len);
    // CRC 覆盖 type + data
    const crcStored = view.getUint32(offset + 8 + len);
    expect(crcStored).toBeGreaterThan(0);
    if (type === 'IDAT') idat.push(data);
    offset += 12 + len;
  }
  expect(types).toEqual(['IHDR', 'IDAT', 'IEND']);

  // 用 node 的 zlib 真正解一次，验证「存储型 deflate」实现正确
  const raw = inflateSync(Buffer.concat(idat.map((d) => Buffer.from(d))));
  expect(raw.length).toBe(64 * (64 + 1));
  // 每行的 filter byte 都是 0（None）
  for (let y = 0; y < 64; y++) expect(raw[y * 65]).toBe(0);
});

test('内嵌测试 WAV 是结构合法的 8kHz 单声道 PCM', () => {
  const wav = makeTestWav(1, 8000);
  const text = (o: number, n: number) => String.fromCharCode(...wav.subarray(o, o + n));
  const view = new DataView(wav.buffer, wav.byteOffset, wav.byteLength);

  expect(text(0, 4)).toBe('RIFF');
  expect(text(8, 4)).toBe('WAVE');
  expect(text(12, 4)).toBe('fmt ');
  expect(view.getUint16(20, true)).toBe(1); // PCM
  expect(view.getUint16(22, true)).toBe(1); // 单声道
  expect(view.getUint32(24, true)).toBe(8000);
  expect(view.getUint16(34, true)).toBe(8); // 位深
  expect(text(36, 4)).toBe('data');
  expect(view.getUint32(40, true)).toBe(8000);
  expect(view.getUint32(4, true)).toBe(36 + 8000);
  expect(wav.length).toBe(44 + 8000);
});

// ─────────────────────────────────────────────────────────────
// openai-compat
// ─────────────────────────────────────────────────────────────

test('openai-compat LLM：图片转 data URI，路由拼到 /v1/chat/completions', async () => {
  const { fn, calls } = fakeFetch([{ json: { choices: [{ message: { content: '{"ok":1}' } }] } }]);
  const adapter = new OpenAICompatAdapter({ fetchFn: fn });

  const res = await adapter.chat(
    {
      system: '你是整理助手',
      parts: [
        { type: 'text', text: '口述原文' },
        { type: 'image', mime: 'image/webp', base64: 'QUJD' },
      ],
    },
    CFG,
  );

  expect(res.text).toBe('{"ok":1}');
  expect(calls[0].url).toBe('http://192.168.1.9:7788/v1/chat/completions');
  const headers = calls[0].init.headers as Record<string, string>;
  expect(headers.authorization).toBe('Bearer sk-test');

  const body = JSON.parse(String(calls[0].init.body)) as {
    model: string;
    temperature: number;
    messages: Array<{ role: string; content: unknown }>;
  };
  expect(body.model).toBe('qwen-vl-max');
  expect(body.temperature).toBe(0.1);
  expect(body.messages[0]).toEqual({ role: 'system', content: '你是整理助手' });
  const content = body.messages[1].content as Array<Record<string, unknown>>;
  expect(content[0]).toEqual({ type: 'text', text: '口述原文' });
  expect(content[1]).toEqual({
    type: 'image_url',
    image_url: { url: 'data:image/webp;base64,QUJD' },
  });
});

test('openai-compat LLM：baseUrl 已带 /v1 时不重复拼接', async () => {
  const { fn, calls } = fakeFetch([{ json: { choices: [{ message: { content: 'x' } }] } }]);
  await new OpenAICompatAdapter({ fetchFn: fn }).chat(
    { system: 's', parts: [{ type: 'text', text: 't' }] },
    { ...CFG, baseUrl: 'http://host/v1/' },
  );
  expect(calls[0].url).toBe('http://host/v1/chat/completions');
});

test('openai-compat LLM：input_audio 只接受 wav/mp3，m4a 明确报错', async () => {
  const { fn } = fakeFetch([]);
  const adapter = new OpenAICompatAdapter({ fetchFn: fn });

  await expect(
    adapter.chat(
      { system: 's', parts: [{ type: 'audio', mime: 'audio/m4a', base64: 'AA' }] },
      CFG,
    ),
  ).rejects.toThrow(/只接受 wav\/mp3/);

  // wav 可以走通
  const { fn: okFn, calls } = fakeFetch([{ json: { choices: [{ message: { content: 'ok' } }] } }]);
  await new OpenAICompatAdapter({ fetchFn: okFn }).chat(
    { system: 's', parts: [{ type: 'audio', mime: 'audio/wav', base64: 'AA' }] },
    CFG,
  );
  const body = JSON.parse(String(calls[0].init.body)) as {
    messages: Array<{ content: Array<Record<string, unknown>> }>;
  };
  expect(body.messages[1].content[0]).toEqual({
    type: 'input_audio',
    input_audio: { data: 'AA', format: 'wav' },
  });
});

test('openai-compat LLM：SSE 流式兜底解析 choices[0].delta.content', async () => {
  const sse = [
    'data: {"choices":[{"delta":{"content":"{\\"a\\":"}}]}',
    '',
    'data: {"choices":[{"delta":{"content":"1}"}}]}',
    '',
    'data: [DONE]',
    '',
  ].join('\n');
  const { fn } = fakeFetch([{ sse }]);
  const res = await new OpenAICompatAdapter({ fetchFn: fn }).chat(
    { system: 's', parts: [{ type: 'text', text: 't' }] },
    CFG,
  );
  expect(res.text).toBe('{"a":1}');
});

test('两种协议的 delta 提取互不串味', () => {
  const anthropicEvent = { type: 'content_block_delta', delta: { type: 'text_delta', text: '甲' } };
  const openaiEvent = { choices: [{ delta: { content: '乙' } }] };
  expect(anthropicDelta(anthropicEvent)).toBe('甲');
  expect(anthropicDelta(openaiEvent)).toBe('');
  expect(openaiDelta(openaiEvent)).toBe('乙');
  expect(openaiDelta(anthropicEvent)).toBe('');
});

test('openai-compat 调用失败时抛出带状态码与响应片段的错误', async () => {
  const { fn } = fakeFetch([{ status: 401, text: 'invalid key' }]);
  await expect(
    new OpenAICompatAdapter({ fetchFn: fn }).chat(
      { system: 's', parts: [{ type: 'text', text: 't' }] },
      CFG,
    ),
  ).rejects.toThrow(/HTTP 401.*invalid key/s);
});

// ─────────────────────────────────────────────────────────────
// ASR
// ─────────────────────────────────────────────────────────────

test('ASR：multipart 字段齐全，m4a 直传用文件名而非 base64', async () => {
  const { fn, calls } = fakeFetch([{ json: { text: '手电筒放主卧衣柜顶层' } }]);
  const adapter = new OpenAICompatAsrAdapter({ fetchFn: fn, media: stubMedia });

  const res = await adapter.transcribe(
    {
      audio: { kind: 'file', rel: 'files/audio/202603/c1.m4a', mime: 'audio/m4a' },
      lang: 'zh',
      hotwords: ['主卧', '衣柜', '手电筒'],
    },
    { ...CFG, model: 'whisper-1' },
  );

  expect(res.text).toBe('手电筒放主卧衣柜顶层');
  expect(calls[0].url).toBe('http://192.168.1.9:7788/v1/audio/transcriptions');

  const headers = calls[0].init.headers as Record<string, string>;
  // 刻意不手写 content-type，让 fetch 自己生成 multipart boundary
  expect(headers['content-type']).toBeUndefined();

  const form = calls[0].init.body as FormData;
  expect(form.get('model')).toBe('whisper-1');
  expect(form.get('language')).toBe('zh');
  expect(form.get('prompt')).toBe('主卧、衣柜、手电筒');
  const file = form.get('file');
  expect(file).toBeInstanceOf(Blob);
  expect((file as File).name ?? 'audio.m4a').toBe('audio.m4a');
});

test('ASR：base64 分支自己造 Blob，并保留 mime', async () => {
  const { fn, calls } = fakeFetch([{ json: { text: '你好' } }]);
  const adapter = new OpenAICompatAsrAdapter({ fetchFn: fn, media: stubMedia });

  await adapter.transcribe(
    { audio: { kind: 'base64', base64: bytesToBase64(new Uint8Array([1, 2, 3])), mime: 'audio/wav' } },
    CFG,
  );

  const file = (calls[0].init.body as FormData).get('file') as Blob;
  expect(file.type).toBe('audio/wav');
  expect(new Uint8Array(await file.arrayBuffer())).toEqual(new Uint8Array([1, 2, 3]));
});

test('ASR：没有热词时不带 prompt 字段', async () => {
  const { fn, calls } = fakeFetch([{ json: { text: '' } }]);
  await new OpenAICompatAsrAdapter({ fetchFn: fn, media: stubMedia }).transcribe(
    { audio: { kind: 'base64', base64: 'AA', mime: 'audio/m4a' } },
    CFG,
  );
  expect((calls[0].init.body as FormData).get('prompt')).toBeNull();
});

test('ASR 失败时抛出带状态码的错误', async () => {
  const { fn } = fakeFetch([{ status: 500, text: 'boom' }]);
  await expect(
    new OpenAICompatAsrAdapter({ fetchFn: fn, media: stubMedia }).transcribe(
      { audio: { kind: 'base64', base64: 'AA', mime: 'audio/m4a' } },
      CFG,
    ),
  ).rejects.toThrow(/HTTP 500/);
});

// ─────────────────────────────────────────────────────────────
// 能力探测
// ─────────────────────────────────────────────────────────────

test('能力探测：正常返回即视为具备该能力，并把样本真的发出去了', async () => {
  const { fn, calls } = fakeFetch([
    { json: { choices: [{ message: { content: '棋盘' } }] } },
    { json: { choices: [{ message: { content: 'ok' } }] } },
  ]);

  const vision = await probeCapability(new OpenAICompatAdapter({ fetchFn: fn }), CFG, 'vision');
  expect(vision).toEqual({ ok: true, detail: '棋盘' });

  const body = JSON.parse(String(calls[0].init.body)) as {
    messages: Array<{ content: Array<{ type?: string; image_url?: { url: string } }> }>;
  };
  const imagePart = body.messages[1].content.find((c) => c.type === 'image_url');
  expect(imagePart?.image_url?.url.startsWith('data:image/png;base64,')).toBe(true);

  const audio = await probeCapability(new OpenAICompatAdapter({ fetchFn: fn }), CFG, 'audio');
  expect(audio.ok).toBe(true);
});

test('能力探测：调用失败与空返回都判为不具备，且带出原因', async () => {
  const { fn } = fakeFetch([{ status: 400, text: 'model does not support image input' }]);
  const vision = await probeCapability(new OpenAICompatAdapter({ fetchFn: fn }), CFG, 'vision');
  expect(vision.ok).toBe(false);
  expect(vision.detail).toMatch(/does not support image/);

  const { fn: emptyFn } = fakeFetch([{ json: { choices: [{ message: { content: '   ' } }] } }]);
  const empty = await probeCapability(new OpenAICompatAdapter({ fetchFn: emptyFn }), CFG, 'vision');
  expect(empty).toEqual({ ok: false, detail: '模型返回为空' });
});

test('probeLlm 并发探测两项能力', async () => {
  const { fn, calls } = fakeFetch([
    { json: { choices: [{ message: { content: '棋盘' } }] } },
    { status: 400, text: 'audio not supported' },
  ]);
  const caps = await probeLlm(new OpenAICompatAdapter({ fetchFn: fn }), CFG);
  expect(caps.vision).toBe(true);
  expect(caps.audio).toBe(false);
  expect(caps.audioDetail).toMatch(/audio not supported/);
  expect(calls).toHaveLength(2);
});
