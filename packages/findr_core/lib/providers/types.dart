/// 模型 Provider 的类型契约。
///
/// ⚠️ **本文件只立类型与契约，HTTP 实现在同目录的其它文件里**
/// （`openai_compat.dart` / `anthropic.dart` / `capabilities.dart` / `factory.dart` / `sse.dart`）。
/// 之所以单独分出这一层：`search/` 的 service / advise / answer 都要拿
/// [LlmProviderAdapter] 当参数类型，测试也要靠 `FakeLlmAdapter` 驱动。
///
/// 两处**有意保留的做法**（都写在下面对应位置）：
///
/// 1. `Part` / `AudioRef` 这类联合类型用 sealed class 表达，好让 `switch`
///    在编译期做穷尽检查；
/// 2. `ChatRequest` **暂不设取消信号字段** —— 取消与超时的惯用做法和插件层耦合，
///    现在凭空定一个类型只是猜（见 [ChatRequest] 的注释）。
library;

/// 送给主 LLM 的输入块。**刻意只有文本与图片** —— 语音不走这条路。
///
/// 需求 3.2 的「模式 1 · LLM 原生音频」（把音频塞进 chat 的 `input_audio`
/// 内容块让模型自己听）**不做**：格式各家不一、拿不到热词、
/// 成本与延迟都明显更高。
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
/// ⚠️ **这里没有取消信号字段** —— 中途取消（用户退出页面、重试时掐掉上一发）
/// 需要和超时配合，而 Dart 侧这两件事的惯用做法和插件层耦合
/// （`HttpClient` 的 `close(force:)`、或 `Future.timeout`），现在凭空定一个类型只是猜。
/// 真需要时再连同 [timeoutMs] 一起定。
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
/// 不是「给 `Error` 实例挂两个属性」，而是换成
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

/// 构造 [HttpStatusException] 的工厂。
HttpStatusException httpStatusError(String prefix, int status, String body) =>
    HttpStatusException(prefix, status, body);

/// `slice(0, 300)` 的等价物：**按 UTF-16 码元截断**。
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

/// 转写结果。
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

  /// 反解，认不出来就用 [fallback]。
  ///
  /// 给「读设置」用：`providerType` 得在运行期验一遍，
  /// Dart 读的是库里的 JSON 字符串，所以必须有个运行时兜底。
  static ProviderType fromWireOr(Object? value, ProviderType fallback) {
    for (final type in values) {
      if (type.wire == value) return type;
    }
    return fallback;
  }
}

/// 主模型 / 转写的调用配置。
///
/// 认证头由适配器自动决定，**不是可配项**（早先的 `authStyle` 已删）：
/// openai-compat 恒发 `Authorization: Bearer`；anthropic 默认也发 Bearer，
/// 仅在 401/403 时改用 legacy 的 `x-api-key` 重试一次。见 `anthropic.dart` 的类注释。
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

  /// 只进系统安全存储 —— DB 的 `settings` 里**没有**它。
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
