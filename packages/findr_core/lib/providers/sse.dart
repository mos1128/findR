/// 共享 SSE 读取 —— 逐字对应 `packages/core/src/providers/sse.ts`（49 行）。
///
/// 网关常强制流式返回，两种协议的差异只在「从事件载荷里取哪段文本」。
/// Anthropic 与 OpenAI 的 delta 结构完全不同，所以抽的是**读取骨架**而不是解析结果。
///
/// Dart 侧的两处对应写法：
/// - TS 的 `TextDecoder.decode(value, {stream:true})`（跨 chunk 保留半个多字节字符）
///   ⇒ Dart 用 `body.transform(Utf8Decoder(...))`，同样是**有状态的流式解码**；
///   注意**不能**用 `utf8.decode(chunk)` 逐块解 —— 一个中文字被切在 chunk 边界就会解成乱码。
/// - `allowMalformed: true` 对应 `new TextDecoder()` 的默认行为（非法序列替换而非抛错）。
library;

import 'dart:convert';

/// 从一条 SSE 事件的 JSON 载荷里取出这段文本（取不到就返回空串）。
typedef SseDeltaExtractor = String Function(Map<String, Object?> event);

/// 边读边拼：把 `data:` 行里的增量文本累加成一个完整字符串。
///
/// 刻意不做的事：**不解析 `event:` / `id:` / `retry:` 字段**（我们只关心 `data:`），
/// 也不把「非 JSON 的行」当错误 —— 注释行与心跳是网关的正常行为，
/// 所以 `jsonDecode` 失败就 `continue`，一次都不往外抛。
Future<String> readSseText(Stream<List<int>> body, SseDeltaExtractor extract) async {
  final out = StringBuffer();
  var buffer = '';

  await for (final chunk in body.transform(const Utf8Decoder(allowMalformed: true))) {
    buffer += chunk;
    final lines = buffer.split('\n');
    // 最后一段可能是被切断的半行，留到下一个 chunk 再拼
    buffer = lines.removeLast();
    for (final line in lines) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('data:')) continue;
      final payload = trimmed.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;
      try {
        out.write(extract(jsonDecode(payload) as Map<String, Object?>));
      } catch (_) {
        // 跳过非 JSON 的事件行（注释、心跳等）
      }
    }
  }
  return out.toString();
}

/// Anthropic Messages：`content_block_delta` + `delta.text_delta`。
String anthropicDelta(Map<String, Object?> event) {
  if (event['type'] != 'content_block_delta') return '';
  final delta = event['delta'];
  if (delta is! Map) return '';
  if (delta['type'] != 'text_delta') return '';
  final text = delta['text'];
  return text is String ? text : '';
}

/// OpenAI chat/completions：`choices[0].delta.content`。
String openaiDelta(Map<String, Object?> event) {
  final choices = event['choices'];
  if (choices is! List || choices.isEmpty) return '';
  final first = choices[0];
  if (first is! Map) return '';
  final delta = first['delta'];
  if (delta is! Map) return '';
  final content = delta['content'];
  return content is String ? content : '';
}
