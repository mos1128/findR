/// API Key 的安全存储。
///
/// Key **只进 Android Keystore / iOS Keychain**：DB 的 settings 与导出的备份都不含它
/// 。这是机密性的第一道屏障；第二道是备份 manifest 的
/// `settings_public` 白名单（见 core 的 `backup/manifest.dart`）——
/// **两道都别拆，任何一道单独都不够**。
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

/// 导入一份备份时，哪些 Key 该写进本机。
final class KeyRestorePlan {
  const KeyRestorePlan({required this.toWrite, required this.skipped});

  /// 要写哪些槽位（值是备份里带回来的那把）。
  final Map<ApiKeySlot, String> toWrite;

  /// 因为本机已经有 Key 而**不动**的槽位数。
  final int skipped;
}

/// 决定导入时该写哪几把 Key：**只填本机为空的槽位**。
///
/// 与「导入不删除本地任何数据」同一条口径 —— 换机场景下新机是空的，一定会写上；
/// 而往一台**已经配好**的机器上再导一次，不该把正在用的 Key 悄悄换掉。
/// 要换 Key 去设置页改，那是显式动作。
///
/// 抽成纯函数是为了这条规则能被单测押住：它写在一个 widget 里就没人测得到了。
KeyRestorePlan planKeyRestore({
  required Map<String, String> incoming,
  required Map<ApiKeySlot, String?> current,
}) {
  final toWrite = <ApiKeySlot, String>{};
  var skipped = 0;
  for (final slot in ApiKeySlot.values) {
    final value = incoming[slot.storageKey];
    if (value == null || value.isEmpty) continue;
    final have = current[slot];
    if (have != null && have.isNotEmpty) {
      skipped++;
      continue;
    }
    toWrite[slot] = value;
  }
  return KeyRestorePlan(toWrite: toWrite, skipped: skipped);
}

/// 设置页只显示掩码（需求 3.6）。
String maskApiKey(String? key) {
  if (key == null || key.isEmpty) return '未配置';
  if (key.length <= 8) return '••••••';
  return '${key.substring(0, 4)}••••${key.substring(key.length - 4)}';
}
