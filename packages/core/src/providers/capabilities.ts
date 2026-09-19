import { testPngBase64 } from './samples';
import type { LLMProviderAdapter, Part, ProviderConfig } from './types';

/**
 * 探测的种类。**只有 text 与 vision 两项** —— 语音那条探测已于 2026-09-19 删除：
 * 它测的是「chat 的 `input_audio` 内容块能不能用」（需求 3.2 的模式 1），
 * 而那条路从来没有被任何业务代码走过（见 `providers/types.ts` 里 `Part` 的注释）。
 * 一个不控制任何功能的探测项，只会给用户多一句看不懂的结论、多一次请求。
 * 语音转写请直接探测 ASR 槽（设置页 ASR 槽的「开始探测」）。
 */
export type CapabilityKind = 'text' | 'vision';

/**
 * 探测结论。刻意做成四态而不是布尔：
 *
 * - `ok`          端点接受了这类输入，而且模型给了正文
 * - `unsupported` 端点/协议明确不接受这类输入（服务端 4xx 说 content 块不合法）
 * - `unknown`     请求被接受了，但模型没给正文 —— **不能据此判定不支持**
 * - `error`       认证 / 模型名 / 网络 / 限流等，与「输入类型」无关的问题
 *
 * 为什么必须有 `unknown`：思考型模型（DeepSeek 的 thinking 模式**默认开启**）会先输出
 * 一段思维链再给正文，两者共用 max_tokens 预算；额度不够时正文可以是空的，
 * 但端点其实完全支持这种输入。此时把结果说成「不支持」是假阴性 —— 用户会以为自己配错了。
 */
export type CapabilityStatus = 'ok' | 'unsupported' | 'unknown' | 'error';

export interface CapabilityResult {
  ok: boolean;
  status: CapabilityStatus;
  /** 通过时是模型回显，否则是人话原因 */
  detail: string;
}

/**
 * 探测用的输出上限。**不能再回到 64**：DeepSeek 思考模式默认 effort=high，
 * 64 个 token 连思维链都走不完，正文必然为空 ⇒ 图片能力被误判成「不支持」。
 * 官方建议思考模式不低于 2048；探测就一次，这点输出量成本可以忽略。
 */
const PROBE_MAX_TOKENS = 2048;

function samplePart(kind: CapabilityKind): Part | null {
  if (kind === 'vision') return { type: 'image', mime: 'image/png', base64: testPngBase64() };
  return null;
}

function promptFor(kind: CapabilityKind): string {
  if (kind === 'vision') return '这张图的图案是什么？用不超过五个字回答。';
  return '这是一次连通性检查，请只回复「ok」。';
}

/** 从服务端错误体里抠出人读的 message（多数是 {"error":{"message":"…"}}） */
function serverMessage(body: string): string {
  const json = /\{[\s\S]*\}/.exec(body);
  if (json) {
    try {
      const parsed = JSON.parse(json[0]) as {
        error?: { message?: string } | string;
        message?: string;
      };
      const err = parsed.error;
      const msg = typeof err === 'string' ? err : err?.message ?? parsed.message;
      if (typeof msg === 'string' && msg.trim()) return msg.trim();
    } catch {
      // 不是 JSON，退回原文
    }
  }
  return body.trim();
}

/** 服务端的这句话是在说「你发的内容块类型我不认」，而不是参数值填错了 */
function looksUnsupported(body: string): boolean {
  return /unknown variant|unsupported|not support|does not support|invalid[_ ]?(type|content)|不支持/i.test(
    body,
  );
}

/** 把「服务端拒绝某类输入」翻译成用户能据此行动的话，并保留一小段原话当证据 */
function explainUnsupported(status: number, body: string): string {
  const raw = serverMessage(body).replace(/\s+/g, ' ').slice(0, 90);
  if (/image_url|image|图片/i.test(body)) {
    return `该端点不接受图片输入（服务端 HTTP ${status}：${raw}）；图片会降级成纯附件，仍可正常记录`;
  }
  return `该端点不接受这类输入（服务端 HTTP ${status}：${raw}）`;
}

function classify(e: unknown): CapabilityResult {
  const httpStatus = (e as { status?: unknown }).status;
  if (typeof httpStatus === 'number') {
    const body = String((e as { body?: unknown }).body ?? '');
    if (httpStatus === 401 || httpStatus === 403) {
      return {
        ok: false,
        status: 'error',
        detail: `认证失败（HTTP ${httpStatus}）：API Key 不对、已过期或没有该模型的权限`,
      };
    }
    if (httpStatus === 404) {
      return {
        ok: false,
        status: 'error',
        detail: `地址或模型名不存在（HTTP 404）：检查 Base URL 与模型名的拼写`,
      };
    }
    if (httpStatus === 429) {
      return { ok: false, status: 'error', detail: '被限流了（HTTP 429），过一会儿再试' };
    }
    if (httpStatus >= 500) {
      return {
        ok: false,
        status: 'error',
        detail: `服务端出错（HTTP ${httpStatus}）：${serverMessage(body).slice(0, 90)}`,
      };
    }
    if (looksUnsupported(body)) {
      return { ok: false, status: 'unsupported', detail: explainUnsupported(httpStatus, body) };
    }
    return {
      ok: false,
      status: 'error',
      detail: `请求被拒绝（HTTP ${httpStatus}）：${serverMessage(body).slice(0, 90)}`,
    };
  }

  return { ok: false, status: 'error', detail: e instanceof Error ? e.message : String(e) };
}

/**
 * 能力探测：用内嵌微型样本发一次 chat，能正常返回即视为该能力可用（技术设计四）。
 *
 * 注意「用户主动关闭图片分析」与「模型不支持图片」是两回事（需求 5.1）：
 * 这里探测的是后者，结果用于把图片分析开关置灰锁定。
 */
export async function probeCapability(
  adapter: LLMProviderAdapter,
  cfg: ProviderConfig,
  kind: CapabilityKind,
): Promise<CapabilityResult> {
  const part = samplePart(kind);

  try {
    const res = await adapter.chat(
      {
        system: '这是一次能力探测，请只回答要求的短语。',
        parts: [{ type: 'text', text: promptFor(kind) }, ...(part ? [part] : [])],
        temperature: 0,
        maxTokens: PROBE_MAX_TOKENS,
        timeoutMs: 60_000,
      },
      cfg,
    );

    const text = res.text.trim();
    if (text) return { ok: true, status: 'ok', detail: text.slice(0, 60) };

    // 正文空了。这是「请求被接受但模型没说话」，不是「端点不支持」。
    const reasoning = (res.reasoning ?? '').trim();
    return {
      ok: false,
      status: 'unknown',
      detail: reasoning
        ? `请求已被接受，但模型只产出了思考过程、没给正文（思考 ${reasoning.length} 字）` +
          '——通常是输出长度上限被思考占满，不代表端点不支持这种输入'
        : '请求已被接受，但模型没返回任何内容，无法判定是否支持',
    };
  } catch (e) {
    return classify(e);
  }
}

export interface ProbedCapabilities {
  /** 配置连通性：纯文本能否跑通。false ⇒ 是配置/网络问题，与能力无关 */
  text: boolean;
  textDetail: string;
  /** 业务用的简化视图：vision=false 会**锁死「图片分析」开关**，见下面 probeLlm 的注释 */
  vision: boolean;
  visionDetail: string;
  /** 给 UI 用的完整结论，让用户能分清「不支持」与「没测出来」 */
  visionStatus: CapabilityStatus;
}

export async function probeLlm(
  adapter: LLMProviderAdapter,
  cfg: ProviderConfig,
): Promise<ProbedCapabilities> {
  // 先单独验一次纯文本：用户最想知道的「我配的对不对」就靠这一步。
  // 也只有它失败了才说明是配置问题 —— 图片失败可能只是能力缺失。
  const text = await probeCapability(adapter, cfg, 'text');
  if (text.status === 'error') {
    // 连纯文本都跑不通，再发图片只会拿到同样的错，白等一个 60 秒超时
    return {
      text: false,
      textDetail: text.detail,
      vision: false,
      visionDetail: `未测（配置本身就没通过：${text.detail}）`,
      visionStatus: 'error',
    };
  }

  const vision = await probeCapability(adapter, cfg, 'vision');
  return {
    text: true,
    textDetail: text.status === 'ok' ? text.detail : `${text.detail}（地址与 Key 是通的）`,
    // ⚠️ `vision: false` 会经 apps 侧的 `visionSupported()` **锁死「图片分析」开关**
    // （需求 3.3 的置灰锁定），所以**只有「端点明确否定」才允许置 false**：
    // 「没测出来」（unknown）不是否定的证据，不能拿它去关用户的功能 ——
    // 这正是第十二版要消灭的那类误判，别让它从后门回来。
    vision: vision.status !== 'unsupported',
    visionDetail: vision.detail,
    visionStatus: vision.status,
  };
}
