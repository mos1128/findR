/// 传输层的公共小件 —— **TS 侧没有这个文件**，是把两处重复逻辑收拢出来的。
///
/// ⚠️ 为什么加这个文件（有意偏离的第三例，前两例是 `util/iso.dart` 与 `providers/media.dart`）：
///
/// 1. **URL 归一化在 TS 里写了两遍**：`openai-compat.ts` 的 `resolveUrl(baseUrl, path)`
///    和 `anthropic.ts` 的 `messagesUrl(baseUrl)` 是**逐字相同的算法**，
///    只是常量部分的 `path` 不同。合成一个函数后，两边仍然传自己的 path，行为可证不变。
/// 2. **超时逻辑在 TS 里也写了两遍半**，且 `AbortController` 的样板更长。
/// 3. 读响应体那两句 `res.text().catch(() => '')` 出现 4 次。
///
/// 这三样都是纯粹的机械重复，Dart 化之后没有保留两份的意义。
library;

import 'dart:async';
import 'dart:convert';

/// 把用户自填的 `baseUrl` 归一成真正的请求地址。
///
/// 规则（与 TS 完全一致）：去掉尾部的 `/`；**若尾部已经是 `/v1` 就不再补 `/v1`**
/// （用户填 `http://host/v1` 和 `http://host` 都得到 `http://host/v1/...`，不会变成 `/v1/v1/...`）。
///
/// [prefix] 只用于报错信息，让「哪个适配器缺 baseUrl」一眼可辨。
String resolveEndpoint(String? baseUrl, String path, String prefix) {
  if (baseUrl == null || baseUrl.isEmpty) {
    throw StateError('$prefix 适配器需要 baseUrl');
  }
  final base = baseUrl.replaceAll(RegExp(r'/+$'), '');
  return RegExp(r'/v1$').hasMatch(base) ? '$base$path' : '$base/v1$path';
}

/// 读完整响应体（UTF-8，非法字节替换而非抛错 —— 对齐 TS `Response.text()` 的宽容行为）。
Future<String> readAllText(Stream<List<int>> body) =>
    const Utf8Decoder(allowMalformed: true).bind(body).join();

/// 读干净但**不抛异常** —— 对应 TS 的 `res.text().catch(() => '')`。
///
/// 两个用途：① 失败路径上取服务端的错误体（读不到就算了，别让读失败盖住真正的 HTTP 错误）；
/// ② **重试前把上一个响应消费掉**，别留下一个没人读的流。
Future<String> readAllTextSwallowing(Stream<List<int>> body) async {
  try {
    return await readAllText(body);
  } catch (_) {
    return '';
  }
}

/// 在 [timeoutMs] 内跑完 [body]；超时抛 [TimeoutException]。
///
/// ⚠️ **与 TS 的 `AbortController` 不完全等价**：那边的 `abort()` 会真的掐断 socket；
/// Dart 的 `Future.timeout` 只是**不再等**，底层连接要等对端关闭或进程回收才算完。
/// 影响面很小 —— 我们的超时是 60~120 秒，能走到就说明对端已经不正常了。
/// 流式那条路另有一层保障：见下面对 SSE 流的处理（`.timeout` 会**真正取消订阅**）。
Future<T> withTimeout<T>(int timeoutMs, Future<T> Function() body) =>
    body().timeout(Duration(milliseconds: timeoutMs));

/// 给 SSE 的字节流套上超时。**这才是真正的取消** —— `Stream.timeout` 到点会
/// `cancel` 掉订阅，底层连接随之释放，而不是留一个没人听的流在那里。
Stream<List<int>> withStreamTimeout(Stream<List<int>> body, int timeoutMs) => body.timeout(
  Duration(milliseconds: timeoutMs),
  onTimeout: (sink) => sink.addError(
    TimeoutException('流式读取超时（${timeoutMs}ms）', Duration(milliseconds: timeoutMs)),
  ),
);

/// `{...}` 或 `null`。整个 `providers/` 都在解析形态不可控的模型/网关回包，
/// 每处都写一次 `is Map ? cast : null` 太吵。
Map<String, Object?>? asMap(Object? value) =>
    value is Map ? value.cast<String, Object?>() : null;

/// JSON 文本 → Map（坏 JSON 给 null，不抛）。
Map<String, Object?>? decodeObject(String raw) {
  try {
    return asMap(jsonDecode(raw));
  } catch (_) {
    return null;
  }
}

/// 数字字段归一成 int（JSON 里 `12` 是 int、`12.0` 是 double，两者都要认）。
int? asInt(Object? value) => value is int ? value : (value is num ? value.toInt() : null);
