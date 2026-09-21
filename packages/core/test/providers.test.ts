import { expect, test } from 'vitest';
import { inflateSync } from 'node:zlib';
import { base64ToBytes, bytesToBase64 } from '../src/util/base64';
import { makeTestPng, makeTestWav } from '../src/providers/samples';
import { anthropicDelta, openaiDelta } from '../src/providers/sse';
import { AnthropicAdapter } from '../src/providers/anthropic';
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

test('anthropic LLM：图片走 source base64 块，认证头默认发 Bearer', async () => {
  const { fn, calls } = fakeFetch([{ json: { content: [{ type: 'text', text: '{"ok":1}' }] } }]);
  const res = await new AnthropicAdapter({ fetchFn: fn }).chat(
    {
      system: '你是整理助手',
      parts: [
        { type: 'text', text: '口述原文' },
        { type: 'image', mime: 'image/webp', base64: 'QUJD' },
      ],
    },
    {
      providerType: 'anthropic',
      baseUrl: 'http://192.168.1.9:7788',
      model: 'claude-sonnet-4',
      apiKey: 'sk-test',
    },
  );

  expect(res.text).toBe('{"ok":1}');
  expect(calls).toHaveLength(1);
  expect(calls[0].url).toBe('http://192.168.1.9:7788/v1/messages');

  const headers = calls[0].init.headers as Record<string, string>;
  expect(headers.authorization).toBe('Bearer sk-test');
  expect(headers['x-api-key']).toBeUndefined();
  expect(headers['anthropic-version']).toBe('2023-06-01');

  const body = JSON.parse(String(calls[0].init.body)) as {
    system: string;
    messages: Array<{ content: Array<Record<string, unknown>> }>;
  };
  expect(body.system).toBe('你是整理助手');
  expect(body.messages[0].content[0]).toEqual({ type: 'text', text: '口述原文' });
  expect(body.messages[0].content[1]).toEqual({
    type: 'image',
    source: { type: 'base64', media_type: 'image/webp', data: 'QUJD' },
  });
});

const ANTHROPIC_CFG: ProviderConfig = {
  providerType: 'anthropic',
  baseUrl: 'http://192.168.1.9:7788',
  model: 'claude-sonnet-4',
  apiKey: 'sk-test',
};

test('anthropic LLM：只在 401/403 时改用 legacy 的 x-api-key 重试一次', async () => {
  const { fn, calls } = fakeFetch([
    { text: '{"error":{"type":"authentication_error"}}', status: 401 },
    { json: { content: [{ type: 'text', text: 'ok' }] } },
  ]);
  const res = await new AnthropicAdapter({ fetchFn: fn }).chat(
    { system: 's', parts: [{ type: 'text', text: 't' }] },
    ANTHROPIC_CFG,
  );

  expect(res.text).toBe('ok');
  expect(calls).toHaveLength(2);

  const first = calls[0].init.headers as Record<string, string>;
  const second = calls[1].init.headers as Record<string, string>;
  expect(first.authorization).toBe('Bearer sk-test');
  expect(second['x-api-key']).toBe('sk-test');
  expect(second.authorization).toBeUndefined();
  // 兜底那次仍要带上协议头，别把 anthropic-version 丢了
  expect(second['anthropic-version']).toBe('2023-06-01');
  expect(second['content-type']).toBe('application/json');
});

test('anthropic LLM：非认证类失败不重试（不拿兜底掩盖真实错误）', async () => {
  const { fn, calls } = fakeFetch([{ text: 'boom', status: 500 }]);
  await expect(
    new AnthropicAdapter({ fetchFn: fn }).chat(
      { system: 's', parts: [{ type: 'text', text: 't' }] },
      ANTHROPIC_CFG,
    ),
  ).rejects.toThrow(/HTTP 500/);
  expect(calls).toHaveLength(1);
});

test('anthropic LLM：兜底也失败时抛出状态码（重试了两次、不静默）', async () => {
  const { fn, calls } = fakeFetch([
    { text: 'no', status: 401 },
    { text: 'still no', status: 401 },
  ]);
  await expect(
    new AnthropicAdapter({ fetchFn: fn }).chat(
      { system: 's', parts: [{ type: 'text', text: 't' }] },
      ANTHROPIC_CFG,
    ),
  ).rejects.toThrow(/HTTP 401/);
  expect(calls).toHaveLength(2);
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
  const { fn, calls } = fakeFetch([{ json: { choices: [{ message: { content: '棋盘' } }] } }]);

  const vision = await probeCapability(new OpenAICompatAdapter({ fetchFn: fn }), CFG, 'vision');
  expect(vision).toMatchObject({ ok: true, status: 'ok', detail: '棋盘' });

  const body = JSON.parse(String(calls[0].init.body)) as {
    messages: Array<{ content: Array<{ type?: string; image_url?: { url: string } }> }>;
  };
  const imagePart = body.messages[1].content.find((c) => c.type === 'image_url');
  expect(imagePart?.image_url?.url.startsWith('data:image/png;base64,')).toBe(true);
});

test('能力探测：端点明确拒绝这类输入 ⇒ unsupported', async () => {
  const { fn } = fakeFetch([{ status: 400, text: 'model does not support image input' }]);
  const vision = await probeCapability(new OpenAICompatAdapter({ fetchFn: fn }), CFG, 'vision');
  expect(vision).toMatchObject({ ok: false, status: 'unsupported' });
  expect(vision.detail).toMatch(/不接受图片输入/);
});

test('能力探测：正文为空但被接受了 ⇒ unknown，绝不是「不支持」', async () => {
  // 第十二版的教训：DeepSeek thinking 默认开启，max_tokens 给不够时正文就是空的，
  // 但端点完全支持这种输入。旧代码把它说成「图片不支持」，用户白折腾了一晚上。
  const { fn } = fakeFetch([
    { json: { choices: [{ message: { content: '   ', reasoning_content: '先看看这张图…' } }] } },
  ]);
  const vision = await probeCapability(new OpenAICompatAdapter({ fetchFn: fn }), CFG, 'vision');

  expect(vision.ok).toBe(false);
  expect(vision.status).toBe('unknown');
  expect(vision.detail).toMatch(/请求已被接受/);
  expect(vision.detail).toMatch(/不代表端点不支持/);
});

test('能力探测：探测请求不给 64 这种会被思考吃光的 max_tokens', async () => {
  const { fn, calls } = fakeFetch([{ json: { choices: [{ message: { content: 'ok' } }] } }]);
  await probeCapability(new OpenAICompatAdapter({ fetchFn: fn }), CFG, 'vision');
  const body = JSON.parse(String(calls[0].init.body)) as { max_tokens: number };
  expect(body.max_tokens).toBeGreaterThanOrEqual(2048);
});

test('能力探测：认证失败是配置问题（error），不是能力问题', async () => {
  const { fn } = fakeFetch([{ status: 401, text: '{"error":{"message":"Authentication Fails"}}' }]);
  const res = await probeCapability(new OpenAICompatAdapter({ fetchFn: fn }), CFG, 'text');
  expect(res).toMatchObject({ ok: false, status: 'error' });
  expect(res.detail).toMatch(/API Key/);
});

test('能力探测：服务端说「不认这种内容块」时翻成人话，并说明降级后果', async () => {
  const body = JSON.stringify({
    error: {
      message:
        'Failed to deserialize the JSON body into the target type: messages[1]: unknown variant `image_url`, expected one of `text`, `file`',
      type: 'invalid_request_error',
    },
  });
  const { fn } = fakeFetch([{ status: 422, text: body }]);
  const vision = await probeCapability(new OpenAICompatAdapter({ fetchFn: fn }), CFG, 'vision');

  expect(vision).toMatchObject({ ok: false, status: 'unsupported' });
  expect(vision.detail).toMatch(/不接受图片输入/);
  expect(vision.detail).toMatch(/降级成纯附件/);
});

test('probeLlm：先验纯文本连通性，再探图片能力（一共两次请求）', async () => {
  const { fn, calls } = fakeFetch([
    { json: { choices: [{ message: { content: 'ok' } }] } },
    { json: { choices: [{ message: { content: '棋盘' } }] } },
  ]);
  const caps = await probeLlm(new OpenAICompatAdapter({ fetchFn: fn }), CFG);

  expect(caps.text).toBe(true);
  expect(caps.vision).toBe(true);
  expect(caps.visionStatus).toBe('ok');
  expect(calls).toHaveLength(2);

  // 第一个请求必须是纯文本，不能带样本 —— 用户要的是「我配的对不对」这个答案
  const first = JSON.parse(String(calls[0].init.body)) as {
    messages: Array<{ content: Array<{ type: string }> }>;
  };
  expect(first.messages[1].content.map((c) => c.type)).toEqual(['text']);
});

test('probeLlm：图片「没测出来」不算不支持 —— vision 必须保持 true，否则会锁死图片分析开关', async () => {
  // apps 侧 visionSupported() 直接读 capabilities.vision 去置灰锁定「图片分析」。
  // 若把 unknown 也算成 false，用户会莫名其妙失去图片分析，且看不出为什么。
  const { fn } = fakeFetch([
    { json: { choices: [{ message: { content: 'ok' } }] } }, // text → ok
    { json: { choices: [{ message: { content: '', reasoning_content: '嗯…' } }] } }, // vision → unknown
  ]);
  const caps = await probeLlm(new OpenAICompatAdapter({ fetchFn: fn }), CFG);

  expect(caps.visionStatus).toBe('unknown');
  expect(caps.vision).toBe(true);
});

test('probeLlm：端点明确否定图片时，vision 才是 false（该锁就锁）', async () => {
  const { fn } = fakeFetch([
    { json: { choices: [{ message: { content: 'ok' } }] } },
    { status: 400, text: 'this model does not support image input' },
  ]);
  const caps = await probeLlm(new OpenAICompatAdapter({ fetchFn: fn }), CFG);

  expect(caps.visionStatus).toBe('unsupported');
  expect(caps.vision).toBe(false);
});

test('probeLlm：配置就没通过时短路，不再白等一个超时', async () => {
  const { fn, calls } = fakeFetch([{ status: 401, text: 'bad key' }]);
  const caps = await probeLlm(new OpenAICompatAdapter({ fetchFn: fn }), CFG);

  expect(caps.text).toBe(false);
  expect(caps.textDetail).toMatch(/认证失败/);
  expect(caps.vision).toBe(false);
  expect(caps.visionDetail).toMatch(/未测/);
  expect(caps.visionStatus).toBe('error');
  expect(calls).toHaveLength(1);
});
