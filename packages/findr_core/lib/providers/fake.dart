/// 脚本化假 Provider。
///
/// 按队列返回预置响应，**队列空时抛错**（模拟调用失败）。测试与骨架期都靠它：
/// `advise` / `answer` / `service` 的用例全是用它把模型这一层控住的。
///
/// ⚠️ 它同时记录每一次请求（[requests]），所以「模型到底看到了什么」是可断言的事实 ——
/// 这正是 `test/search/advise_test.dart` 里「裁决时模型真的看到了库存」那条用例的押注点。
library;

import 'types.dart';

final class FakeLlmAdapter implements LlmProviderAdapter {
  FakeLlmAdapter([List<String> responses = const <String>[]]) {
    for (final r in responses) {
      _queue.add(ChatResponse(text: r));
    }
  }

  /// 按调用顺序记录下来的请求 —— 与 `fake.requests` 同源。
  final List<ChatRequest> requests = <ChatRequest>[];

  final List<ChatResponse> _queue = <ChatResponse>[];

  void push(String response) => _queue.add(ChatResponse(text: response));

  @override
  Future<ChatResponse> chat(ChatRequest req, ProviderConfig cfg) async {
    requests.add(req);
    if (_queue.isEmpty) {
      throw StateError('FakeLlmAdapter: 无预置响应（模拟调用失败）');
    }
    return _queue.removeAt(0);
  }
}
