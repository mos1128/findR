/// OpenAI Responses 协议适配器（/v1/responses）。
///
/// 适配 OpenAI 最新的 Responses 协议，与 Chat Completions（/v1/chat/completions）形成明确区分。
/// 参考 ccg-gateway (services/translate/openai_responses.rs) 的协议结构与用量统计语义。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sse.dart';
import 'transport.dart';
import 'types.dart';

const int _defaultResponsesTimeoutMs = 120000;

Map<String, String> _authHeaders(ProviderConfig cfg) {
  final headers = <String, String>{'authorization': 'Bearer ${cfg.apiKey ?? ''}'};
  final ua = cfg.userAgent;
  if (ua != null && ua.isNotEmpty) headers['user-agent'] = ua;
  return headers;
}

final class OpenAIResponsesAdapter implements LlmProviderAdapter {
  OpenAIResponsesAdapter({http.Client? client, int? timeoutMs})
    : _client = client ?? http.Client(),
      _timeoutMs = timeoutMs ?? _defaultResponsesTimeoutMs;

  final http.Client _client;
  final int _timeoutMs;

  @override
  Future<ChatResponse> chat(ChatRequest req, ProviderConfig cfg) async {
    final url = resolveEndpoint(cfg.baseUrl, '/responses', 'openai-responses');

    final content = <Map<String, Object?>>[];
    for (final part in req.parts) {
      switch (part) {
        case TextPart(:final text):
          content.add({'type': 'input_text', 'text': text});
        case ImagePart(:final mime, :final base64):
          content.add({
            'type': 'input_image',
            'image_url': 'data:$mime;base64,$base64',
          });
      }
    }

    final timeoutMs = req.timeoutMs ?? _timeoutMs;
    final bodyMap = <String, Object?>{
      'model': cfg.model,
      'temperature': req.temperature ?? 0.1,
      'max_output_tokens': req.maxTokens ?? 4096,
      'store': false,
      'input': [
        {
          'role': 'user',
          'content': content,
        },
      ],
    };
    if (req.system.isNotEmpty) {
      bodyMap['instructions'] = req.system;
    }

    final request = http.Request('POST', Uri.parse(url))
      ..headers.addAll({
        ..._authHeaders(cfg),
        'content-type': 'application/json',
        'accept': 'application/json',
      })
      ..body = jsonEncode(bodyMap);

    return withTimeout(timeoutMs, () async {
      final res = await _client.send(request);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final text = await readAllTextSwallowing(res.stream);
        throw httpStatusError('openai-responses', res.statusCode, text);
      }

      final ctype = res.headers['content-type'] ?? '';
      if (ctype.contains('text/event-stream')) {
        return ChatResponse(
          text: await readSseText(
            withStreamTimeout(res.stream, timeoutMs),
            openaiResponsesDelta,
          ),
        );
      }

      final data = decodeObject(await readAllText(res.stream));
      final root = data?['response'] is Map ? asMap(data!['response']) : data;

      // 遍历 output 提取文本与思考
      final outputList = root?['output'];
      final textBuf = StringBuffer();
      String? reasoning;

      if (outputList is List) {
        for (final item in outputList) {
          if (item is! Map) continue;
          final type = item['type'];
          if (type == 'message') {
            final parts = item['content'];
            if (parts is List) {
              for (final p in parts) {
                if (p is Map) {
                  final t = p['output_text'] ?? p['text'];
                  if (t is String) textBuf.write(t);
                } else if (p is String) {
                  textBuf.write(p);
                }
              }
            } else if (parts is String) {
              textBuf.write(parts);
            }
          } else if (type == 'reasoning') {
            final summary = item['summary'];
            if (summary is List) {
              final r = summary.whereType<Map>().map((m) => m['text']).whereType<String>().join('\n');
              if (r.isNotEmpty) reasoning = r;
            }
          }
        }
      }

      // 用量抽取 (参考 ccg-gateway openai_responses.rs)
      final usage = asMap(root?['usage']);
      final inputTokens = asInt(usage?['input_tokens']);
      final outputTokens = asInt(usage?['output_tokens']);
      final totalTokens = asInt(usage?['total_tokens']) ??
          ((inputTokens != null || outputTokens != null) ? ((inputTokens ?? 0) + (outputTokens ?? 0)) : null);

      return ChatResponse(
        text: textBuf.toString(),
        reasoning: reasoning,
        usage: usage == null
            ? null
            : ChatUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                totalTokens: totalTokens,
              ),
      );
    });
  }
}
