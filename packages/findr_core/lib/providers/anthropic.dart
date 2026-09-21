/// Anthropic Messages 协议适配器 —— 逐字对应 `packages/core/src/providers/anthropic.ts`（122 行）。
///
/// **认证头自动适配，用户不需要选**（第十八版起）：
/// - 默认发 `Authorization: Bearer` —— 官方文档现在的首选写法，网关也认这个；
/// - **只有**收到 401 / 403（HTTP 层明确说「凭证不被接受」）才改用 `x-api-key` 重试一次。
///   `x-api-key` 是官方标注的 legacy 兜底、仍受支持；留这一步只为兼容只认它的老端点。
/// - 为什么不把两个头一起发：官方没有说明两者并存时用哪个，**不猜**。
/// - 为什么只在 401/403 兜底：与「调用失败」和「能力不支持」必须分开判同源 ——
///   其余错误一律不重试，别用它掩盖真实失败。
///
/// 兼容 ccg-gateway 等本地网关：网关按 UA 路由，需 userAgent 伪装 claude-cli。
/// 只送文本与图片 —— 语音转写走专用 ASR（Anthropic 协议本身没有音频输入）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sse.dart';
import 'transport.dart';
import 'types.dart';

const int _defaultTimeoutMs = 120000;

/// Anthropic 协议版本。**这是协议的一部分，不是可调参数。**
const String _anthropicVersion = '2023-06-01';

final class AnthropicAdapter implements LlmProviderAdapter {
  AnthropicAdapter({http.Client? client, int? timeoutMs})
    : _client = client ?? http.Client(),
      _timeoutMs = timeoutMs ?? _defaultTimeoutMs;

  final http.Client _client;
  final int _timeoutMs;

  @override
  Future<ChatResponse> chat(ChatRequest req, ProviderConfig cfg) async {
    final baseUrl = cfg.baseUrl;
    if (baseUrl == null || baseUrl.isEmpty) {
      throw StateError('anthropic 适配器需要 baseUrl');
    }
    final url = resolveEndpoint(baseUrl, '/messages', 'anthropic');

    // Anthropic 的图片块和 OpenAI 完全不同：不是 data URI，而是显式的 base64 source 块
    final content = <Map<String, Object?>>[];
    for (final part in req.parts) {
      switch (part) {
        case TextPart(:final text):
          content.add({'type': 'text', 'text': text});
        case ImagePart(:final mime, :final base64):
          content.add({
            'type': 'image',
            'source': {'type': 'base64', 'media_type': mime, 'data': base64},
          });
      }
    }

    final baseHeaders = <String, String>{
      'content-type': 'application/json',
      'accept': 'application/json',
      'anthropic-version': _anthropicVersion,
    };
    final ua = cfg.userAgent;
    if (ua != null && ua.isNotEmpty) baseHeaders['user-agent'] = ua;

    final body = jsonEncode({
      'model': cfg.model,
      'max_tokens': req.maxTokens ?? 4096,
      'temperature': req.temperature,
      'system': req.system,
      'messages': [
        {'role': 'user', 'content': content},
      ],
    });

    // ⚠️ 注意 `temperature` 与 OpenAI 那边不同：这里是**原样透传**（可为 null），
    // 那边有 `?? 0.1` 的兜底。TS 就是这个差异，别顺手"对齐"掉。
    Future<http.StreamedResponse> send(Map<String, String> auth) {
      final request = http.Request('POST', Uri.parse(url))
        ..headers.addAll({...baseHeaders, ...auth})
        ..body = body;
      return _client.send(request);
    }

    final timeoutMs = req.timeoutMs ?? _timeoutMs;

    // 整个流程（含可能的第二次发送、含读体）共用一个超时 —— 与 TS 的单个 AbortController 同口径
    return withTimeout(timeoutMs, () async {
      var res = await send({'authorization': 'Bearer ${cfg.apiKey ?? ''}'});

      // 只有 HTTP 层明确拒绝凭证（401/403）才换 legacy 头发第二次；其余错误照原样抛出
      if (res.statusCode == 401 || res.statusCode == 403) {
        // 先把上一个响应体读完，别留下未消费的响应（这条路很少走到，成本可忽略）
        await readAllTextSwallowing(res.stream);
        res = await send({'x-api-key': cfg.apiKey ?? ''});
      }

      if (res.statusCode < 200 || res.statusCode >= 300) {
        final text = await readAllTextSwallowing(res.stream);
        throw httpStatusError('anthropic', res.statusCode, text);
      }

      final ctype = res.headers['content-type'] ?? '';
      if (ctype.contains('text/event-stream')) {
        return ChatResponse(
          text: await readSseText(withStreamTimeout(res.stream, timeoutMs), anthropicDelta),
        );
      }

      final data = decodeObject(await readAllText(res.stream));
      // 正文可能是多个 text 块拼起来的（Anthropic 允许 content 是数组）
      final blocks = data?['content'];
      final text = blocks is List
          ? blocks
                .whereType<Map>()
                .where((b) => b['type'] == 'text' && b['text'] is String)
                .map((b) => b['text'] as String)
                .join()
          : '';
      final usage = asMap(data?['usage']);
      return ChatResponse(
        text: text,
        usage: usage == null
            ? null
            : ChatUsage(
                inputTokens: asInt(usage['input_tokens']),
                outputTokens: asInt(usage['output_tokens']),
              ),
      );
    });
  }
}
