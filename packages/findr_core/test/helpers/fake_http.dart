import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 一条预置的假响应。与 TS `providers.test.ts` 的 `FakeResponse` 同形。
final class FakeResponse {
  const FakeResponse({
    this.json,
    this.text,
    this.status = 200,
    this.sse,
    this.delayMs = 0,
  });

  /// 走 JSON 回包（会 `jsonEncode` 成字节）。
  final Object? json;

  /// 走纯文本回包。
  final String? text;

  final int status;

  /// 走 SSE：原始的事件流文本，`content-type` 自动带上 `text/event-stream`。
  final String? sse;

  /// 先等一会儿再回 —— 给「超时必须生效」那类用例用。
  final int delayMs;
}

/// 假 `http.Client` —— 对应 TS 的 `fakeFetch`。
///
/// ⚠️ **比 TS 那版捕获的信息更多**：TS 的 `fetchFn` 只能拿到 `init.body`（FormData 对象），
/// 断言 multipart 字段得靠 `form.get('x')`。Dart 这边直接把**原始的 `http.BaseRequest`**
/// 存下来，于是 `MultipartRequest.fields` / `.files` 可以按名字断言，
/// 比解析编码后的字节更稳（也顺带把「字段名到底是什么」这件事真正测到了）。
///
/// 注意：`finalize()` 是**一次性**的，而且 `MultipartRequest` 正是在 `finalize()` 里
/// 才把 `content-type: multipart/form-data; boundary=…` 写进 headers。
/// 所以下面**先 finalize 取体、再快照 headers**，顺序不能反。
final class FakeHttpClient extends http.BaseClient {
  FakeHttpClient(this._responses);

  final List<FakeResponse> _responses;

  /// 每次 send 的原始请求对象（`http.Request` 或 `http.MultipartRequest`）。
  final List<http.BaseRequest> calls = [];

  /// 每次 send 的实际请求体字节。
  final List<Uint8List> bodies = [];

  /// 每次 send 时的 headers 快照（**已 finalize**，所以 multipart 的 boundary 在里面）。
  final List<Map<String, String>> headers = [];

  /// 已发出的请求数 —— 用来断言「重试了几次」「有没有短路」。
  int get callCount => calls.length;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls.add(request);
    final bytes = await request.finalize().toBytes();
    bodies.add(bytes);
    headers.add(Map<String, String>.from(request.headers));

    if (_responses.isEmpty) {
      throw StateError('FakeHttpClient: 没有预置响应');
    }
    final spec = _responses.removeAt(0);

    if (spec.delayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: spec.delayMs));
    }

    if (spec.sse != null) {
      return http.StreamedResponse(
        _chunked(spec.sse!),
        spec.status,
        headers: {'content-type': 'text/event-stream'},
      );
    }
    if (spec.text != null) {
      return http.StreamedResponse(
        Stream.value(Uint8List.fromList(utf8.encode(spec.text!))),
        spec.status,
      );
    }
    return http.StreamedResponse(
      Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(spec.json ?? {})))),
      spec.status,
      headers: {'content-type': 'application/json'},
    );
  }

  /// 把 SSE 文本切成**小块**再吐出去 —— 刻意不一次性给整段：
  /// `readSseText` 的缓冲逻辑（半行留到下一个 chunk）必须被真的走到，
  /// 否则「跨 chunk 的半行」这个最容易错的地方就永远测不到。
  static Stream<List<int>> _chunked(String text) {
    final bytes = utf8.encode(text);
    const chunkSize = 7;
    final chunks = <List<int>>[];
    for (var i = 0; i < bytes.length; i += chunkSize) {
      chunks.add(bytes.sublist(i, i + chunkSize > bytes.length ? bytes.length : i + chunkSize));
    }
    return Stream.fromIterable(chunks);
  }

  /// 取第 [index] 次请求的 JSON 请求体（断言 URL / headers / 字段时最常用）。
  Map<String, Object?> jsonBody(int index) =>
      jsonDecode(utf8.decode(bodies[index])) as Map<String, Object?>;

  /// 取第 [index] 次请求的 multipart 请求对象。
  http.MultipartRequest multipart(int index) => calls[index] as http.MultipartRequest;

  /// 第 [index] 次请求的完整 URL。
  String url(int index) => calls[index].url.toString();
}
