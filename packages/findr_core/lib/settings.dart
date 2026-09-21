/// 设置项的**唯一权威定义** —— 逐字对应 `packages/core/src/settings.ts`（138 行）。
///
/// DB 的 `settings` 表只存这里列出的非机密项；API Key 只进 SecureStore（键 `llm` / `asr`），
/// **导出备份永不包含**（技术设计四）。
///
/// 第十九版删掉了 `pipeline` 键（它只装「低置信确认阈值」这一个值）；第二十版连阈值本身
/// 带整条「待确认」功能一起删了。老安装的 settings 表里会残留一行没人读的 `pipeline` JSON
/// —— **无害，不做迁移**；它也不再进备份包（白名单里没有了），老备份包里带来的那一行
/// 导入时照旧插进表，同样没人读。
///
/// ⚠️ **Dart 侧与 TS 的结构性差异（本节最重要的一条）**：
/// TS 那边 `getSetting<LlmSettings>(db, key)` 是**结构类型直接当类型用**，
/// 缺字段就是 `undefined`；`{...DEFAULTS, ...(stored ?? {})}` 是**浅合并**。
/// Dart 没有结构类型，所以这里为每个设置项写了显式的 `fromJson`，
/// 并**逐字复刻浅合并的语义**（`containsKey` 判断，键在就取它、哪怕值是 null）。
library;

import 'db/driver.dart';
import 'db/settings.dart' as db_settings;
import 'providers/capabilities.dart';
import 'providers/transport.dart';
import 'providers/types.dart';

/// settings 表的键名。**这就是存在库里的字面值，改不得。**
abstract final class SettingsKeys {
  static const String llm = 'llm';
  static const String asr = 'asr';
  static const String capture = 'capture';
  static const String search = 'search';
}

/// 主模型能力探测的缓存（存在 `llm` 设置里的 `capabilities` 字段）。
final class CapabilityCache {
  const CapabilityCache({
    required this.vision,
    required this.visionDetail,
    required this.probedAt,
    required this.probedModel,
    this.text,
    this.textDetail,
    this.visionStatus,
  });

  /// 纯文本连通性：跑通就说明「地址 / Key / 模型名」这几样没配错，
  /// 图片与音频失败就只剩「能力缺失」一种解释。第十二版新增，旧缓存里没有这一项。
  final bool? text;
  final String? textDetail;

  final bool vision;
  final String visionDetail;

  /// 图片能力的完整结论，用来在 UI 上区分「不支持」与「没测出来」。第十二版新增。
  final CapabilityStatus? visionStatus;

  /// ⚠️ **写它的人必须用 `util/iso.dart` 的 `isoUtc()`**（TS 侧是 `new Date().toISOString()`），
  /// 与库里其余时间列同口径。
  final String probedAt;

  /// 探测时的模型名；与当前模型不一致即视为过期，需要重探。
  final String probedModel;

  Map<String, Object?> toJson() => {
    if (text != null) 'text': text,
    if (textDetail != null) 'textDetail': textDetail,
    'vision': vision,
    'visionDetail': visionDetail,
    if (visionStatus != null) 'visionStatus': visionStatus!.wire,
    'probedAt': probedAt,
    'probedModel': probedModel,
  };

  static CapabilityCache? fromJson(Object? raw) {
    final map = asMap(raw);
    if (map == null) return null;
    final vision = map['vision'];
    final visionDetail = map['visionDetail'];
    final probedAt = map['probedAt'];
    final probedModel = map['probedModel'];
    if (vision is! bool || visionDetail is! String || probedAt is! String || probedModel is! String) {
      // 缓存的形状不对就整条丢掉 —— 调用方会把它当成「没探过」，重探一次而已
      return null;
    }
    return CapabilityCache(
      vision: vision,
      visionDetail: visionDetail,
      probedAt: probedAt,
      probedModel: probedModel,
      text: map['text'] is bool ? map['text'] as bool : null,
      textDetail: map['textDetail'] is String ? map['textDetail'] as String : null,
      visionStatus: CapabilityStatus.fromWire(map['visionStatus']),
    );
  }
}

/// 主 LLM 的配置。
///
/// 第十八版删掉了 `authStyle` —— 认证头已改为适配器自动适配（见 `providers/types.dart`）。
/// 老安装里存的 `authStyle` 键会留在 JSON 里但**被忽略**，无需迁移、不影响覆盖安装。
final class LlmSettings {
  const LlmSettings({
    required this.providerType,
    required this.model,
    this.baseUrl,
    this.userAgent,
    this.capabilities,
  });

  /// TS 的类型是 `'anthropic' | 'openai-compat'`（一个更窄的 union）。
  /// Dart 侧直接复用 [ProviderType]，由 `makeLlmAdapter` 在运行时挡掉 gemini/fake
  /// —— 类型层面的收窄在 Dart 里要再建一个枚举，不值那个复杂度。
  final ProviderType providerType;

  final String? baseUrl;
  final String model;
  final String? userAgent;
  final CapabilityCache? capabilities;

  Map<String, Object?> toJson() => {
    'providerType': providerType.wire,
    if (baseUrl != null) 'baseUrl': baseUrl,
    'model': model,
    if (userAgent != null) 'userAgent': userAgent,
    if (capabilities != null) 'capabilities': capabilities!.toJson(),
  };

  static LlmSettings? fromJson(Object? raw) {
    final map = asMap(raw);
    if (map == null) return null;
    return LlmSettings(
      // 值不合规时退回 openai-compat：它是「用户自填 baseUrl 的兼容端点」这条主路径的协议，
      // 也是设置页的默认项。**注意这与 TS 不同** —— 那边未知值会让 switch 漏空、
      // 返回 undefined 后在调用点崩掉；这里退化成可用配置，最多是协议选错（用户在设置页看得见）。
      providerType: ProviderType.fromWireOr(map['providerType'], ProviderType.openaiCompat),
      model: map['model'] is String ? map['model'] as String : '',
      baseUrl: map['baseUrl'] is String ? map['baseUrl'] as String : null,
      userAgent: map['userAgent'] is String ? map['userAgent'] as String : null,
      capabilities: CapabilityCache.fromJson(map['capabilities']),
    );
  }
}

/// 语音转写的配置。协议**只有** openai-compat 一个（Anthropic 协议没有音频输入）。
final class AsrSettings {
  const AsrSettings({required this.model, this.baseUrl});

  final String? baseUrl;
  final String model;

  Map<String, Object?> toJson() => {
    'providerType': ProviderType.openaiCompat.wire,
    if (baseUrl != null) 'baseUrl': baseUrl,
    'model': model,
  };

  static AsrSettings? fromJson(Object? raw) {
    final map = asMap(raw);
    if (map == null) return null;
    return AsrSettings(
      model: map['model'] is String ? map['model'] as String : '',
      baseUrl: map['baseUrl'] is String ? map['baseUrl'] as String : null,
    );
  }
}

final class CaptureSettings {
  const CaptureSettings({
    required this.visionDefault,
    required this.visionLast,
    required this.maxAnalyzeImages,
  });

  /// 图片分析开关的默认值（需求 5.1：默认开）。
  final bool visionDefault;

  /// 记忆上次选择；null 表示用户还没手动切过。
  final bool? visionLast;

  /// 单卡送模型分析的图片张数上限。需求把「可配 N 张」列为非 MVP，这里是固定护栏。
  final int maxAnalyzeImages;

  Map<String, Object?> toJson() => {
    'visionDefault': visionDefault,
    'visionLast': visionLast,
    'maxAnalyzeImages': maxAnalyzeImages,
  };
}

const CaptureSettings defaultCaptureSettings = CaptureSettings(
  visionDefault: true,
  visionLast: null,
  maxAnalyzeImages: 6,
);

/// 检索行为开关（第十四版新增）。
///
/// [autoAnswer] 是把 L2 从「手动点」改成「自动补」的开关，默认**关**。
/// 关的理由不是省钱（单次多花的 token 换算下来约 0.17 分，可忽略），而是两条：
/// 1. **隐私**：L2 会把最多 8 条命中片段发给模型。关着的时候，用户不点按钮就
///    **不外发任何记忆内容**；开着等于每次搜索都外发。
///    对一个「本地记忆库」来说这是性质变化，必须由用户自己选。
/// 2. **冗余**：有结果时 L1 的卡片列表往往已经够用，一段总结常常只是把可扫的列表
///    复述成要读的文字。
///
/// 开启后答案**追加在列表下方**（不是置顶）—— 渐进式返回时置顶会把列表推下去，形成跳动。
final class SearchSettings {
  const SearchSettings({required this.autoAnswer});

  final bool autoAnswer;

  Map<String, Object?> toJson() => {'autoAnswer': autoAnswer};
}

const SearchSettings defaultSearchSettings = SearchSettings(autoAnswer: false);

/// 浅合并：**键在就用它的值（哪怕值是 null）**，键不在才用默认值。对齐 TS 的 `{...DEFAULTS, ...stored}`。
bool _mergeBool(Map<String, Object?>? stored, String key, bool fallback) {
  if (stored == null || !stored.containsKey(key)) return fallback;
  final value = stored[key];
  return value is bool ? value : fallback;
}

bool? _mergeBoolOrNull(Map<String, Object?>? stored, String key) {
  if (stored == null || !stored.containsKey(key)) return null;
  final value = stored[key];
  return value is bool ? value : null;
}

int _mergeInt(Map<String, Object?>? stored, String key, int fallback) {
  if (stored == null || !stored.containsKey(key)) return fallback;
  final value = asInt(stored[key]);
  return value ?? fallback;
}

SearchSettings readSearchSettings(SqliteDriver db) {
  final stored = asMap(db_settings.getSetting<Object?>(db, SettingsKeys.search));
  return SearchSettings(
    autoAnswer: _mergeBool(stored, 'autoAnswer', defaultSearchSettings.autoAnswer),
  );
}

void writeSearchSettings(SqliteDriver db, SearchSettings value) {
  db_settings.setSetting(db, SettingsKeys.search, value.toJson());
}

LlmSettings? readLlmSettings(SqliteDriver db) =>
    LlmSettings.fromJson(db_settings.getSetting<Object?>(db, SettingsKeys.llm));

void writeLlmSettings(SqliteDriver db, LlmSettings value) {
  db_settings.setSetting(db, SettingsKeys.llm, value.toJson());
}

AsrSettings? readAsrSettings(SqliteDriver db) =>
    AsrSettings.fromJson(db_settings.getSetting<Object?>(db, SettingsKeys.asr));

void writeAsrSettings(SqliteDriver db, AsrSettings value) {
  db_settings.setSetting(db, SettingsKeys.asr, value.toJson());
}

CaptureSettings readCaptureSettings(SqliteDriver db) {
  final stored = asMap(db_settings.getSetting<Object?>(db, SettingsKeys.capture));
  return CaptureSettings(
    visionDefault: _mergeBool(stored, 'visionDefault', defaultCaptureSettings.visionDefault),
    visionLast: _mergeBoolOrNull(stored, 'visionLast'),
    maxAnalyzeImages: _mergeInt(stored, 'maxAnalyzeImages', defaultCaptureSettings.maxAnalyzeImages),
  );
}

void writeCaptureSettings(SqliteDriver db, CaptureSettings value) {
  db_settings.setSetting(db, SettingsKeys.capture, value.toJson());
}

/// 本次录入实际使用的图片分析开关：用户手动切过就用上次的选择，否则用默认值。
/// 模型不支持图片时恒定关（需求 3.3 置灰锁定）。
bool effectiveVision(CaptureSettings capture, bool visionSupported) {
  if (!visionSupported) return false;
  return capture.visionLast ?? capture.visionDefault;
}

/// 探测结果是否已过期（换了模型就要重探）。
bool capabilitiesStale(LlmSettings llm) {
  final caps = llm.capabilities;
  if (caps == null) return true;
  return caps.probedModel != llm.model;
}
