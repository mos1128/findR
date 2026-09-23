/// 从模型输出里抠出 JSON 并校验。
///
/// 模型很爱做的两件事：把 JSON 包在 markdown 围栏里、在最后一个元素后面留个逗号。
/// 这一层就是专门伺候这两个毛病的 —— **失败是常态，不是异常**，所以返回结果而不是抛。
library;

import 'dart:convert';

/// [parseModelJson] 的结果。用「成功带值 / 失败带错」的联合表达，
/// Dart 里用 sealed class：调用方 `switch` 时是穷尽的，不会漏掉失败分支。
sealed class ParseResult<T> {
  const ParseResult();
}

final class ParseOk<T> extends ParseResult<T> {
  const ParseOk(this.value);

  final T value;
}

final class ParseFailure<T> extends ParseResult<T> {
  const ParseFailure(this.error);

  final String error;
}

/// 提取模型输出中的 JSON 对象：**先剥 markdown 围栏，再取首个 `{` 到末个 `}`**。
///
/// 取「首个到末个」而不是「配平括号」，是因为模型经常在 JSON 后面跟一句解释 ——
/// 那句话说里带 `}` 的概率，远低于它把 JSON 写得不完整的概率。
String? extractJson(String raw) {
  var text = raw.trim();
  final fence = RegExp(
    r'```(?:json)?\s*([\s\S]*?)```',
    caseSensitive: false,
  ).firstMatch(text);
  if (fence != null) text = fence.group(1)!.trim();
  final first = text.indexOf('{');
  final last = text.lastIndexOf('}');
  if (first == -1 || last <= first) return null;
  return text.substring(first, last + 1);
}

/// 修复高频语法问题：尾逗号。
String fixJson(String text) =>
    text.replaceAllMapped(RegExp(r',\s*([}\]])'), (m) => m.group(1)!);

/// 抠 JSON → 解析 → 校验。[schema] 返回 `null` 表示「字段校验失败」。
///
/// [schema] 是一个「JSON → T?」的取值器：`P2Output` 传 [P2OutputSchema.tryParse]。
ParseResult<T> parseModelJson<T>(String raw, T? Function(Object?) schema) {
  final extracted = extractJson(raw);
  if (extracted == null) return ParseFailure<T>('输出中未找到 JSON 对象');

  final Object? obj;
  try {
    obj = jsonDecode(fixJson(extracted));
  } on FormatException catch (e) {
    return ParseFailure<T>(e.message);
  } catch (e) {
    return ParseFailure<T>(e.toString());
  }

  final value = schema(obj);
  if (value == null) return ParseFailure<T>('输出字段校验失败');
  return ParseOk<T>(value);
}
