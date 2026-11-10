/// API Key 的安全存储。
///
/// Key **只进 Android Keystore / iOS Keychain**，不写进 DB 的 settings。
/// 导出备份时由平台层把本机 Key 全量放进包的 `apiKeys` 字段（见 `backup.dart`），
/// 导入时再写回安全存储。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 只有两档：主模型与语音转写各一把。
enum ApiKeySlot {
  llm('findr.llm.apiKey'),
  asr('findr.asr.apiKey');

  const ApiKeySlot(this.storageKey);

  /// ⚠️ **这些名字是持久化契约，改不得**。
  /// 改名字就等于把用户已经存好的 Key 弄丢 —— 而且界面上只会显示「未配置」，
  /// 很难联想到是「名字改了」。
  final String storageKey;
}

/// 端口：界面与 runtime 只依赖它，测试可换内存实现。
abstract interface class ApiKeyStore {
  Future<String?> read(ApiKeySlot slot);

  /// 传 null 或空串即删除。
  Future<void> write(ApiKeySlot slot, String? value);
}

/// 真机实现（Keystore / Keychain）。
///
/// 插件在 Android 上的默认算法是 **AES-GCM** 加密数据 + **RSA-OAEP** 包密钥（API 23+），
/// 且 `resetOnError` 默认为 true：解密失败时**丢掉那一条**，而不是永久报错。
/// 对 API Key 来说这笔买卖是划算的 —— 它随时可以重填，而一条永远读不出来的记录会让
/// 设置页说不清「为什么明明填过却说没配」。
final class SecureApiKeyStore implements ApiKeyStore {
  const SecureApiKeyStore();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  Future<String?> read(ApiKeySlot slot) async {
    try {
      return await _storage.read(key: slot.storageKey);
    } catch (_) {
      // 设备不支持安全存储时不该让整个 App 起不来
      return null;
    }
  }

  @override
  Future<void> write(ApiKeySlot slot, String? value) async {
    final next = (value == null || value.isEmpty) ? null : value;
    if (next == null) {
      await _storage.delete(key: slot.storageKey);
    } else {
      await _storage.write(key: slot.storageKey, value: next);
    }
  }
}

/// 内存实现。测试用；也让「安全存储不可用」时有个可用的降级位。
final class MemoryApiKeyStore implements ApiKeyStore {
  MemoryApiKeyStore([Map<ApiKeySlot, String>? initial])
    : _values = <ApiKeySlot, String>{...?initial};

  final Map<ApiKeySlot, String> _values;

  @override
  Future<String?> read(ApiKeySlot slot) async => _values[slot];

  @override
  Future<void> write(ApiKeySlot slot, String? value) async {
    if (value == null || value.isEmpty) {
      _values.remove(slot);
    } else {
      _values[slot] = value;
    }
  }
}

/// 导入后每个 Key 槽位应该变成什么。
///
/// **全量覆盖**：备份里有的值直接覆盖本机；备份里没有的槽位返回 `null`，表示清空本机。
/// 调用方对 `null` 执行删除即可。
///
/// 抽成纯函数是为了这条规则能被单测押住：它写在一个 widget 里就没人测得到了。
Map<ApiKeySlot, String?> keysToRestore(Map<String, String> incoming) => <ApiKeySlot, String?>{
  for (final slot in ApiKeySlot.values)
    slot: (incoming[slot.storageKey]?.isNotEmpty ?? false)
        ? incoming[slot.storageKey]
        : null,
};

/// 设置页只显示掩码（需求 3.6）。
String maskApiKey(String? key) {
  if (key == null || key.isEmpty) return '未配置';
  if (key.length <= 8) return '••••••';
  return '${key.substring(0, 4)}••••${key.substring(key.length - 4)}';
}
