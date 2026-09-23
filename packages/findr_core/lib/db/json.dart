/// 卡片里的数组/对象类列统一以 JSON 文本存储，这里收口两个方向的转换。
///
/// **解码刻意收紧了一处**：
/// 直接把 `JSON.parse` 的结果当成数组返回的话，列里若存的是对象，
/// 它会返回一个「类型是数组、实际是对象」的值，等到下游 `.map()` 才炸（且现场已经离得很远）。
/// 这里显式判 `is! List` 返回 null —— 与 `listSettings` 那句「坏值不阻塞」同一个口径。
library;

import 'dart:convert';

String? toJson(Object? value) => value == null ? null : jsonEncode(value);

List<T>? parseJsonArray<T>(Object? value) {
  if (value == null) return null;
  try {
    final decoded = jsonDecode(value.toString());
    if (decoded is! List) return null;
    return List<T>.from(decoded);
  } catch (_) {
    return null;
  }
}
