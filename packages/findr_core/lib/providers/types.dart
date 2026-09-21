/// 模型 Provider 的类型契约 —— 逐字对应 `packages/core/src/providers/types.ts`（84 行）。
///
/// ⚠️ **本文件只立类型与契约，没有 HTTP 实现。** 实现（`openai-compat.ts` / `anthropic.ts` /
/// `capabilities.ts` / `factory.ts` / `sse.ts`）留到译 `providers/` 那一块时补。
/// 之所以现在就把它立起来：`search/` 的 service / advise / answer 都要拿
/// [LlmProviderAdapter] 当参数类型，测试也要靠 `FakeLlmAdapter` 驱动。
///
/// 两处**有意偏离 TS**（都写在下面对应位置）：
///
/// 1. TS 的 union 类型（`Part` / `AudioRef`）改用 sealed class —— Dart 的惯用法，
///    且下游 switch 时是穷尽检查的；
/// 2. TS 的 `ChatRequest.signal?: AbortSignal` **暂不设对应字段** —— Dart 没有完全对等的
///    标准原语（见 [ChatRequest] 的注释），译 `providers/` 实现时连同超时一起定。
library;

/// 送给主 LLM 的输入块。**刻意只有文本与图片** —— 语音不走这条路。
///
/// 需求 3.2 原本还有一条「模式 1 · LLM 原生音频」（把音频塞进 chat 的 `input_audio`
/// 内容块让模型自己听），已于 2026-09-19 废止：格式各家不一、拿不到热词、
/// 成本与延迟都明显更高，且从 1.0 起就没有任何代码走过它。
/// 转写一律走 [AsrProviderAdapter.transcribe]（`/audio/transcriptions`）。
sealed class Part {
  const Part();
}

/// 文本块。
final class TextPart extends Part {
  const TextPart(this.text);

  final String text;
}

/// 图片块。`base64` 是**不含 data URL 前缀**的裸 base64。
final class ImagePart extends Part {
  const ImagePart({required this.mime, required this.base64});

  final String mime;
  final String base64;
}

/// 一次 chat 调用的输入。
///
/// ⚠️ **TS 有 `signal?: AbortSignal`，这里没有对应字段** —— 它是用来中途取消请求的
/// （用户退出页面、重试时掐掉上一发）。Dart 侧取消 + 超时的惯用做法和插件层耦合
/// （`HttpClient` 的 `close(force:)`、或 `Future.timeout`），现在凭空定一个类型只是猜。
/// 译 `providers/` 的实现时再连同 [timeoutMs] 一起定。
final class ChatRequest {
  const ChatRequest({
    required this.system,
    required this.parts,
    this.temperature,
    this.maxTokens,
    this.timeoutMs,
  });

  final String system;
  final List<Part> parts;

  /// 我们全程用 `0.1` —— 抽取类任务要的是稳定复现，不是文采。
  final double? temperature;

  final int? maxTokens;
  final int? timeoutMs;
}

/// 一次 chat 调用的输出。
final class ChatResponse {
  const ChatResponse({required this.text, this.reasoning, this.usage});

  final String text;

  /// 思考型模型的过程文本（DeepSeek 的 `reasoning_content`）。默认不参与业务逻辑，
  /// 只在 [text] 为空时用来解释「为什么是空的」：思考模式默认开启且会吃掉 max_tokens 预算，
  /// 额度不够时正文可以是空的，此时它往往是唯一产出。
  final String? reasoning;

  final ChatUsage? usage;
}

/// token 用量（各家的字段名归一到这里）。
final class ChatUsage {
  const ChatUsage({this.inputTokens, this.outputTokens});

  final int? inputTokens;
  final int? outputTokens;
}

/// 带 HTTP 状态码的调用失败。调用方据此区分「认证 / 模型名 / 限流」与「端点不接受这种输入」。
///
/// TS 那边是「给 `Error` 实例挂两个属性」（`httpStatusError()` 工厂），Dart 里换成
/// 一个真的异常类型 —— 判类型比判 `err.name === 'HttpStatusError'` 可靠。
final class HttpStatusException implements Exception {
  HttpStatusException(this.prefix, this.status, this.body)
    : message = '$prefix 调用失败 HTTP $status: ${_clip(body, 300)}';

  /// 调用方的自述前缀（如「主模型」「转写」），用来拼人看的错误串。
  final String prefix;

  final int status;
  final String body;
  final String message;

  @override
  String toString() => message;
}

/// 构造 [HttpStatusException] —— 保留 TS 的同名工厂形状，调用点不用改写法。
HttpStatusException httpStatusError(String prefix, int status, String body) =>
    HttpStatusException(prefix, status, body);

/// TS 的 `body.slice(0, 300)`。**按 UTF-16 码元截断**，与 JS 同口径。
String _clip(String value, int max) => value.length > max ? value.substring(0, max) : value;

/// 音频引用。走原生文件直传，m4a 不进内存；
/// base64 分支供测试与设置页的 ASR 槽探测（内嵌 1 秒 WAV）使用。
sealed class AudioRef {
  const AudioRef();

  /// 上传给服务端的 MIME。
  String get mime;
}

/// 文件引用：`rel` 是 App 沙盒内的相对路径。
final class AudioFileRef extends AudioRef {
  const AudioFileRef({required this.rel, required this.mime});

  final String rel;

  @override
  final String mime;
}

/// 内嵌 base64（测试与探测用）。
final class AudioBase64Ref extends AudioRef {
  const AudioBase64Ref({required this.base64, required this.mime});

  final String base64;

  @override
  final String mime;
}

/// 一次转写调用的输入。
final class TranscribeRequest {
  const TranscribeRequest({
    required this.audio,
    this.filename,
    this.lang,
    this.hotwords,
    this.timeoutMs,
  });

  final AudioRef audio;

  /// 上传文件名 —— 部分服务端靠后缀嗅探格式。
  final String? filename;

  final String? lang;

  /// 热词表（从记忆库实体名来的），提高专有名词的转写准确率。
  final List<String>? hotwords;

  final int? timeoutMs;
}

/// 转写结果。TS 侧是匿名结构 `{ text: string }`。
final class TranscribeResult {
  const TranscribeResult(this.text);

  final String text;
}

enum ProviderType {
  openaiCompat('openai-compat'),
  anthropic('anthropic'),
  gemini('gemini'),
  fake('fake');

  const ProviderType(this.wire);

  /// 落设置、进配置的字面值 —— **这就是格式，改不得**。
  final String wire;

  static ProviderType fromWire(String value) {
    for (final type in values) {
      if (type.wire == value) return type;
    }
    throw ArgumentError.value(value, 'value', '未知的 provider 类型');
  }
}

/// 主模型 / 转写的调用配置。
///
/// 认证头由适配器自动决定，**不再是可配项**（第十八版删掉了 `authStyle`）：
/// openai-compat 恒发 `Authorization: Bearer`；anthropic 默认也发 Bearer，
/// 仅在 401/403 时改用 legacy 的 `x-api-key` 重试一次。见 `anthropic.ts` 的类注释。
final class ProviderConfig {
  const ProviderConfig({
    required this.providerType,
    required this.model,
    this.baseUrl,
    this.apiKey,
    this.userAgent,
  });

  final ProviderType providerType;

  /// 用户自填的地址。**这是我们唯一的外部出口**（没有我们的服务器）。
  final String? baseUrl;

  final String model;

  /// 只进系统安全存储，永不进备份包。
  final String? apiKey;

  /// 部分网关按 User-Agent 路由，需要伪装成已知客户端（如 `claude-cli/…`）。
  final String? userAgent;
}

/// 主模型适配器：一问一答。
abstract interface class LlmProviderAdapter {
  Future<ChatResponse> chat(ChatRequest req, ProviderConfig cfg);
}

/// 转写适配器：音频进、文字出。
abstract interface class AsrProviderAdapter {
  Future<TranscribeResult> transcribe(TranscribeRequest req, ProviderConfig cfg);
}
