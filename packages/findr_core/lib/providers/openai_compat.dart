/// OpenAI 兼容协议适配器。
///
/// 覆盖 OpenAI、DeepSeek、通义、火山、GLM、硅基流动等一切兼容端点。
/// 图片走 `image_url` 的 data URI。**不发音频**：chat 的 `input_audio` 内容块只认 wav/mp3
/// （我们录的是 m4a），且 DeepSeek / 通义 / GLM 这类端点在反序列化阶段就会拒掉它。
/// 语音转写一律走下面的 [OpenAICompatAsrAdapter]（`/audio/transcriptions`）。
///
/// Dart 侧的对应关系（都写在下面对应位置）：
/// - 注入 `fetchFn` ⇒ 注入 `http.Client`（在测试里换掉整条网络）；
/// - `AbortController` ⇒ [withTimeout]，细节见 `transport.dart` 的注释；
/// - `FormData` ⇒ `http.MultipartRequest`（**同样刻意不手写 content-type**，交给库生成 boundary）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

import '../util/base64.dart';
import 'media.dart';
import 'sse.dart';
import 'transport.dart';
import 'types.dart';

/// 默认超时（毫秒）。模型出长文可能慢，所以给得比 ASR 宽。
const int _defaultChatTimeoutMs = 120000;

/// ASR 超时：只上传一小段 m4a，快得多。
const int _defaultAsrTimeoutMs = 60000;

/// 认证头由适配器自动决定，**不再是可配项**：openai-compat 恒发 `Authorization: Bearer`。
Map<String, String> _authHeaders(ProviderConfig cfg) {
  final headers = <String, String>{'authorization': 'Bearer ${cfg.apiKey ?? ''}'};
  final ua = cfg.userAgent;
  if (ua != null && ua.isNotEmpty) headers['user-agent'] = ua;
  return headers;
}

// ─────────────────────────────────────────────────────────────
// LLM：/v1/chat/completions
// ─────────────────────────────────────────────────────────────

final class OpenAICompatAdapter implements LlmProviderAdapter {
  /// [client] 传 null 就走真实网络；测试传假 client（见 `test/providers/`）。
  ///
  /// `timeoutMs` 写成 `int?` + 在初始化列表里 `?? 默认值`（而不是形参默认值），
  /// 是为了让「显式传 null」也落到默认值上，而不是被当成 0。
  OpenAICompatAdapter({http.Client? client, int? timeoutMs})
    : _client = client ?? http.Client(),
      _timeoutMs = timeoutMs ?? _defaultChatTimeoutMs;

  final http.Client _client;
  final int _timeoutMs;

  @override
  Future<ChatResponse> chat(ChatRequest req, ProviderConfig cfg) async {
    final url = resolveEndpoint(cfg.baseUrl, '/chat/completions', 'openai-compat');

    // 图片转成 `data:<mime>;base64,<裸 base64>` —— 这是 OpenAI 视觉协议规定的外形
    final content = <Map<String, Object?>>[];
    for (final part in req.parts) {
      switch (part) {
        case TextPart(:final text):
          content.add({'type': 'text', 'text': text});
        case ImagePart(:final mime, :final base64):
          content.add({
            'type': 'image_url',
            'image_url': {'url': 'data:$mime;base64,$base64'},
          });
      }
    }

    final timeoutMs = req.timeoutMs ?? _timeoutMs;
    final request = http.Request('POST', Uri.parse(url))
      ..headers.addAll({
        ..._authHeaders(cfg),
        'content-type': 'application/json',
        'accept': 'application/json',
      })
      ..body = jsonEncode({
        'model': cfg.model,
        'temperature': req.temperature ?? 0.1,
        'max_tokens': req.maxTokens ?? 4096,
        'messages': [
          {'role': 'system', 'content': req.system},
          {'role': 'user', 'content': content},
        ],
      });

    return withTimeout(timeoutMs, () async {
      final res = await _client.send(request);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final text = await readAllTextSwallowing(res.stream);
        throw httpStatusError('openai-compat', res.statusCode, text);
      }

      // 网关常强制流式返回：content-type 说了是 SSE 就得按 SSE 读，
      // 否则 `jsonDecode` 会在一堆 `data: {...}` 行上直接失败。
      final ctype = res.headers['content-type'] ?? '';
      if (ctype.contains('text/event-stream')) {
        return ChatResponse(text: await _readSseText(res.stream, openaiDelta, timeoutMs));
      }

      final data = decodeObject(await readAllText(res.stream));
      final message = asMap(asMap(_firstOrNull(data?['choices']))?['message']);
      final usage = asMap(data?['usage']);
      final contentText = message?['content'];
      final reasoningText = message?['reasoning_content'];
      return ChatResponse(
        text: contentText is String ? contentText : '',
        reasoning: reasoningText is String ? reasoningText : null,
        usage: usage == null
            ? null
            : ChatUsage(
                inputTokens: asInt(usage['prompt_tokens']),
                outputTokens: asInt(usage['completion_tokens']),
              ),
      );
    });
  }
}

Object? _firstOrNull(Object? list) => list is List && list.isNotEmpty ? list[0] : null;

Future<String> _readSseText(Stream<List<int>> body, SseDeltaExtractor extract, int timeoutMs) =>
    readSseText(withStreamTimeout(body, timeoutMs), extract);

// ─────────────────────────────────────────────────────────────
// ASR：/v1/audio/transcriptions
// ─────────────────────────────────────────────────────────────

/// 上传文件名：没有显式给就用 mime 推一个 —— **服务端常靠后缀嗅探格式**。
String _filenameFor(TranscribeRequest req) {
  final explicit = req.filename;
  if (explicit != null && explicit.isNotEmpty) return explicit;
  final mime = req.audio.mime;
  if (mime.contains('wav')) return 'audio.wav';
  if (mime.contains('mp3') || mime.contains('mpeg')) return 'audio.mp3';
  if (mime.contains('webm')) return 'audio.webm';
  return 'audio.m4a';
}

/// mime → `MediaType`。解析不了就退回 `application/octet-stream` ——
/// `MediaType.parse` 遇到畸形值会抛（不像给对象挂个字符串那样无所谓），所以必须兜住。
MediaType _mediaType(String mime) {
  try {
    return MediaType.parse(mime);
  } catch (_) {
    return MediaType('application', 'octet-stream');
  }
}

/// OpenAI 兼容 ASR（`/v1/audio/transcriptions`）。**m4a 直传不转码。**
///
/// 刻意不手写 content-type —— 交给 `MultipartRequest` 生成 multipart 的 boundary。
final class OpenAICompatAsrAdapter implements AsrProviderAdapter {
  /// [media] 是必填的文件端口，所以放**位置参数**：Dart 的具名参数不允许下划线开头，
  /// 而 `this._media` 这种字段形参只有位置参数能用（命名参数会编译不过）。
  OpenAICompatAsrAdapter(this._media, {http.Client? client, int? timeoutMs})
    : _client = client ?? http.Client(),
      _timeoutMs = timeoutMs ?? _defaultAsrTimeoutMs;

  final http.Client _client;
  final int _timeoutMs;
  final MediaIo _media;

  @override
  Future<TranscribeResult> transcribe(TranscribeRequest req, ProviderConfig cfg) {
    final url = resolveEndpoint(cfg.baseUrl, '/audio/transcriptions', 'openai-compat');
    final timeoutMs = req.timeoutMs ?? _timeoutMs;
    final filename = _filenameFor(req);

    return withTimeout(timeoutMs, () async {
      final form = http.MultipartRequest('POST', Uri.parse(url))
        ..headers.addAll(_authHeaders(cfg))
        ..fields['model'] = cfg.model;

      final lang = req.lang;
      if (lang != null && lang.isNotEmpty) form.fields['language'] = lang;

      // 需求 3.2：热词用来提升房间名与常用物品名的转写准确率
      final hotwords = req.hotwords;
      if (hotwords != null && hotwords.isNotEmpty) {
        form.fields['prompt'] = hotwords.join('、');
      }

      switch (req.audio) {
        case AudioFileRef(:final rel, :final mime):
          // 走 App 侧的文件端口（实现应流式读盘，不把 m4a 整体读进内存）
          form.files.add(await _media.audioPart(rel, mime, filename));
        case AudioBase64Ref(:final base64, :final mime):
          form.files.add(
            http.MultipartFile.fromBytes(
              'file',
              base64ToBytes(base64),
              filename: filename,
              contentType: _mediaType(mime),
            ),
          );
      }

      final res = await _client.send(form);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final text = await readAllTextSwallowing(res.stream);
        throw httpStatusError('ASR', res.statusCode, text);
      }
      final data = decodeObject(await readAllText(res.stream));
      return TranscribeResult(data?['text'] is String ? data!['text'] as String : '');
    });
  }
}
