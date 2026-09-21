/// 能力探测 —— 逐字对应 `packages/core/src/providers/capabilities.ts`（211 行）。
///
/// 探测的种类**只有 text 与 vision 两项** —— 语音那条探测已于 2026-09-19 删除：
/// 它测的是「chat 的 `input_audio` 内容块能不能用」（需求 3.2 的模式 1），
/// 而那条路从来没有被任何业务代码走过。一个不控制任何功能的探测项，
/// 只会给用户多一句看不懂的结论、多一次请求。**语音转写请直接探测 ASR 槽。**
library;

import 'samples.dart';
import 'transport.dart';
import 'types.dart';

/// 探测的种类。
enum CapabilityKind { text, vision }

/// 探测结论。**刻意做成四态而不是布尔**：
///
/// - [ok]          端点接受了这类输入，而且模型给了正文
/// - [unsupported] 端点/协议明确不接受这类输入（服务端 4xx 说 content block 不合法）
/// - [unknown]     请求被接受了，但模型没给正文 —— **不能据此判定不支持**
/// - [error]       认证 / 模型名 / 网络 / 限流等，与「输入类型」无关的问题
///
/// 为什么必须有 [unknown]：思考型模型（DeepSeek 的 thinking 模式**默认开启**）会先输出
/// 一段思维链再给正文，两者共用 `max_tokens` 预算；额度不够时正文可以是空的，
/// 但端点其实完全支持这种输入。此时把结果说成「不支持」是**假阴性** ——
/// 用户会以为自己配错了（第十二版就栽在这里）。
///
/// [wire] 是落进 `CapabilityCache.visionStatus` 的字面值，**改不得**。
enum CapabilityStatus {
  ok('ok'),
  unsupported('unsupported'),
  unknown('unknown'),
  error('error');

  const CapabilityStatus(this.wire);

  final String wire;

  /// 反解；不认识的字符串给 null（老缓存里可能有、也可能没有这一项）。
  static CapabilityStatus? fromWire(Object? value) {
    for (final status in values) {
      if (status.wire == value) return status;
    }
    return null;
  }
}

final class CapabilityResult {
  const CapabilityResult({required this.ok, required this.status, required this.detail});

  final bool ok;
  final CapabilityStatus status;

  /// 通过时是模型回显，否则是人话原因。
  final String detail;
}

/// 探测用的输出上限。**不能再回到 64**：DeepSeek 思考模式默认 `effort=high`，
/// 64 个 token 连思维链都走不完，正文必然为空 ⇒ 图片能力被误判成「不支持」。
/// 官方建议思考模式不低于 2048；探测就一次，这点输出量成本可以忽略。
const int probeMaxTokens = 2048;

Part? _samplePart(CapabilityKind kind) {
  if (kind == CapabilityKind.vision) {
    return ImagePart(mime: 'image/png', base64: testPngBase64());
  }
  return null;
}

String _promptFor(CapabilityKind kind) {
  if (kind == CapabilityKind.vision) return '这张图的图案是什么？用不超过五个字回答。';
  return '这是一次连通性检查，请只回复「ok」。';
}

/// 从服务端错误体里抠出人读的 message（多数是 `{"error":{"message":"…"}}`）。
String serverMessage(String body) {
  final json = RegExp(r'\{[\s\S]*\}').firstMatch(body);
  if (json != null) {
    final parsed = decodeObject(json.group(0)!);
    if (parsed != null) {
      final error = parsed['error'];
      final fromError = error is String ? error : asMap(error)?['message'];
      final msg = fromError ?? parsed['message'];
      if (msg is String && msg.trim().isNotEmpty) return msg.trim();
    }
  }
  return body.trim();
}

/// 服务端的这句话是在说「你发的内容块类型我不认」，而不是参数值填错了。
bool _looksUnsupported(String body) => RegExp(
  r'unknown variant|unsupported|not support|does not support|invalid[_ ]?(type|content)|不支持',
  caseSensitive: false,
).hasMatch(body);

/// 把「服务端拒绝某类输入」翻译成用户能据此行动的话，并保留一小段原话当证据。
String _explainUnsupported(int status, String body) {
  final raw = serverMessage(body).replaceAll(RegExp(r'\s+'), ' ');
  final evidence = raw.length > 90 ? raw.substring(0, 90) : raw;
  if (RegExp(r'image_url|image|图片', caseSensitive: false).hasMatch(body)) {
    return '该端点不接受图片输入（服务端 HTTP $status：$evidence）；图片会降级成纯附件，仍可正常记录';
  }
  return '该端点不接受这类输入（服务端 HTTP $status：$evidence）';
}

/// 把异常归类成四态结论。
///
/// ⚠️ **Dart 侧用真类型判**（`is HttpStatusException`），TS 那边是鸭子类型
/// （`typeof (e as {status?}).status === 'number'`）。全仓只有 [HttpStatusException]
/// 带 `status`，所以两者结果一致；Dart 这样写还能让分析器盯着，改坏了编译就不过。
CapabilityResult _classify(Object e) {
  if (e is HttpStatusException) {
    final status = e.status;
    final body = e.body;

    if (status == 401 || status == 403) {
      return CapabilityResult(
        ok: false,
        status: CapabilityStatus.error,
        detail: '认证失败（HTTP $status）：API Key 不对、已过期或没有该模型的权限',
      );
    }
    if (status == 404) {
      return const CapabilityResult(
        ok: false,
        status: CapabilityStatus.error,
        detail: '地址或模型名不存在（HTTP 404）：检查 Base URL 与模型名的拼写',
      );
    }
    if (status == 429) {
      return const CapabilityResult(
        ok: false,
        status: CapabilityStatus.error,
        detail: '被限流了（HTTP 429），过一会儿再试',
      );
    }
    if (status >= 500) {
      return CapabilityResult(
        ok: false,
        status: CapabilityStatus.error,
        detail: '服务端出错（HTTP $status）：${_clip(serverMessage(body), 90)}',
      );
    }
    if (_looksUnsupported(body)) {
      return CapabilityResult(
        ok: false,
        status: CapabilityStatus.unsupported,
        detail: _explainUnsupported(status, body),
      );
    }
    return CapabilityResult(
      ok: false,
      status: CapabilityStatus.error,
      detail: '请求被拒绝（HTTP $status）：${_clip(serverMessage(body), 90)}',
    );
  }

  // TS 是 `e instanceof Error ? e.message : String(e)`。Dart 里所有对象都有 toString()，
  // 且异常本身就是 Exception/Error ⇒ 这条分支不再需要区分，直接 toString()。
  return CapabilityResult(ok: false, status: CapabilityStatus.error, detail: e.toString());
}

String _clip(String value, int max) => value.length > max ? value.substring(0, max) : value;

/// 能力探测：用内嵌微型样本发一次 chat，能正常返回即视为该能力可用（技术设计四）。
///
/// 注意「用户主动关闭图片分析」与「模型不支持图片」是两回事（需求 5.1）：
/// 这里探测的是后者，结果用于把图片分析开关**置灰锁定**。
Future<CapabilityResult> probeCapability(
  LlmProviderAdapter adapter,
  ProviderConfig cfg,
  CapabilityKind kind,
) async {
  final part = _samplePart(kind);
  try {
    final res = await adapter.chat(
      ChatRequest(
        system: '这是一次能力探测，请只回答要求的短语。',
        parts: [TextPart(_promptFor(kind)), ?part],
        temperature: 0,
        maxTokens: probeMaxTokens,
        timeoutMs: 60000,
      ),
      cfg,
    );

    final text = res.text.trim();
    if (text.isNotEmpty) {
      return CapabilityResult(ok: true, status: CapabilityStatus.ok, detail: _clip(text, 60));
    }

    // 正文空了。这是「请求被接受但模型没说话」，**不是「端点不支持」**。
    final reasoning = (res.reasoning ?? '').trim();
    return CapabilityResult(
      ok: false,
      status: CapabilityStatus.unknown,
      detail: reasoning.isNotEmpty
          ? '请求已被接受，但模型只产出了思考过程、没给正文（思考 ${reasoning.length} 字）'
                '——通常是输出长度上限被思考占满，不代表端点不支持这种输入'
          : '请求已被接受，但模型没返回任何内容，无法判定是否支持',
    );
  } catch (e) {
    return _classify(e);
  }
}

/// 给 UI 用的完整结论，让用户能分清「不支持」与「没测出来」。
final class ProbedCapabilities {
  const ProbedCapabilities({
    required this.text,
    required this.textDetail,
    required this.vision,
    required this.visionDetail,
    required this.visionStatus,
  });

  /// 配置连通性：纯文本能否跑通。false ⇒ 是配置/网络问题，与能力无关。
  final bool text;
  final String textDetail;

  /// 业务用的简化视图：`vision == false` 会**锁死「图片分析」开关**（见 [probeLlm] 的注释）。
  final bool vision;
  final String visionDetail;

  /// 给 UI 用的完整结论，让用户能分清「不支持」与「没测出来」。
  final CapabilityStatus visionStatus;
}

Future<ProbedCapabilities> probeLlm(LlmProviderAdapter adapter, ProviderConfig cfg) async {
  // 先单独验一次纯文本：用户最想知道的「我配的对不对」就靠这一步。
  // **也只有它失败了才说明是配置问题** —— 图片失败可能只是能力缺失。
  final text = await probeCapability(adapter, cfg, CapabilityKind.text);
  if (text.status == CapabilityStatus.error) {
    // 连纯文本都跑不通，再发图片只会拿到同样的错，白等一个 60 秒超时
    return ProbedCapabilities(
      text: false,
      textDetail: text.detail,
      vision: false,
      visionDetail: '未测（配置本身就没通过：${text.detail}）',
      visionStatus: CapabilityStatus.error,
    );
  }

  final vision = await probeCapability(adapter, cfg, CapabilityKind.vision);
  return ProbedCapabilities(
    text: true,
    textDetail: text.status == CapabilityStatus.ok ? text.detail : '${text.detail}（地址与 Key 是通的）',
    // ⚠️ `vision: false` 会经 apps 侧的 `visionSupported()` **锁死「图片分析」开关**
    // （需求 3.3 的置灰锁定），所以**只有「端点明确否定」才允许置 false**：
    // 「没测出来」（unknown）不是否定的证据，不能拿它去关用户的功能 ——
    // 这正是第十二版要消灭的那类误判，别让它从后门回来。
    vision: vision.status != CapabilityStatus.unsupported,
    visionDetail: vision.detail,
    visionStatus: vision.status,
  );
}
