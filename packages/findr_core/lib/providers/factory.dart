/// 适配器工厂 —— 逐字对应 `packages/core/src/providers/factory.ts`（50 行）。
///
/// 职责只有一件：**把「设置项 + Key」翻译成「可用的适配器」**。
/// Key 由调用方从安全存储取出后传进来 —— core 不碰 SecureStore。
library;

import 'package:http/http.dart' as http;

import '../settings.dart';
import 'anthropic.dart';
import 'media.dart';
import 'openai_compat.dart';
import 'types.dart';

/// 建适配器时可注入的传输件（测试用假 client 换掉整条网络）。
final class AdapterOptions {
  const AdapterOptions({this.client, this.timeoutMs});

  final http.Client? client;
  final int? timeoutMs;
}

/// 设置项 + Key → 适配器可用的配置。
ProviderConfig toProviderConfig(LlmSettings llm, String? apiKey) => ProviderConfig(
  providerType: llm.providerType,
  baseUrl: llm.baseUrl,
  model: llm.model,
  apiKey: apiKey,
  userAgent: llm.userAgent,
);

ProviderConfig toAsrProviderConfig(AsrSettings asr, String? apiKey) => ProviderConfig(
  providerType: ProviderType.openaiCompat,
  baseUrl: asr.baseUrl,
  model: asr.model,
  apiKey: apiKey,
);

/// 按设置里的协议建主模型适配器。
///
/// ⚠️ **有意偏离 TS**：TS 的 `switch` 没有 `default`，遇到 `gemini` / `fake`
/// （类型上排除、但设置是 JSON 读出来的）会**返回 `undefined`**，然后在调用点
/// `adapter.chat(...)` 崩成「undefined 不是函数」—— 一个没有信息量的错。
/// Dart 的 switch 必须穷尽，这里干脆显式抛 [UnsupportedError]，
/// 报错里带上协议名，让「哪个配置不对」一眼可辨。
LlmProviderAdapter makeLlmAdapter(LlmSettings llm, [AdapterOptions opts = const AdapterOptions()]) {
  switch (llm.providerType) {
    case ProviderType.anthropic:
      return AnthropicAdapter(client: opts.client, timeoutMs: opts.timeoutMs);
    case ProviderType.openaiCompat:
      return OpenAICompatAdapter(client: opts.client, timeoutMs: opts.timeoutMs);
    case ProviderType.gemini:
    case ProviderType.fake:
      throw UnsupportedError('主模型不支持 ${llm.providerType.wire} 协议');
  }
}

/// 按设置建 ASR 适配器。
///
/// ⚠️ **有意偏离 TS**：TS 的 `AsrSettings` 里带着 `providerType: 'openai-compat'`
/// 这个字段（只有一个合法值），于是 `switch` 也就只有一条分支、其余返回 `undefined`。
/// Dart 侧直接把这个不可能出现的分支去掉了：[AsrSettings] 不再存 `providerType` 字段，
/// 但 `toJson()` 仍写出 `providerType: 'openai-compat'` —— **落库的 JSON 形状与 TS 完全一致**，
/// 老数据与老备份包都能对上。
AsrProviderAdapter makeAsrAdapter(
  AsrSettings asr,
  MediaIo media, [
  AdapterOptions opts = const AdapterOptions(),
]) => OpenAICompatAsrAdapter(
  media,
  client: opts.client,
  timeoutMs: opts.timeoutMs,
);
