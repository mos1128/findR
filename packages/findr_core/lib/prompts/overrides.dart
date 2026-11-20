/// 用户自改的提示词。
///
/// 能改的只有「怎么想」的那几段散文；**输出 schema 与调用示例不放开** ——
/// schema 的字段名与解析器一一对应，改一个词整条解析就会落到「待整理」，
/// 而用户从报错里看不出是提示词改坏的。
///
/// 存法：`settings` 表一个 [SettingsKeys.prompts] 键，
/// `{"p1": {"text": "...", "preset": "8f2a1c3d"}}`。
/// `preset` 是**保存当时默认正文的哈希**：发版改了默认，它就与新哈希对不上，
/// 界面据此提示「默认已更新」。手写版本号迟早有忘记加一的那天，哈希不会。
library;

import '../db/driver.dart';
import '../db/settings.dart' as db_settings;
import '../providers/transport.dart' show asMap;
import '../settings.dart';
import 'templates.dart';

/// 四个可自定义的提示词。`wire` 是存进 settings 的键，改不得。
enum PromptId {
  p1('p1', '录入', '把口述或照片整理成卡片'),
  p2('p2', '检索', '判断一句话是找东西还是求建议'),
  p3('p3', '回答', '用命中的卡片组织答案'),
  p4('p4', '建议', '从整库清单里挑这个情景用得上的东西');

  const PromptId(this.wire, this.title, this.use);

  final String wire;

  /// 界面上这一步叫什么。
  final String title;

  /// 这条提示词在哪一段流程里生效。
  final String use;

  static PromptId? fromWire(String value) {
    for (final id in values) {
      if (id.wire == value) return id;
    }
    return null;
  }
}

/// 默认正文：可编辑的那几段。schema、示例与 `{{变量}}` 的注入由各 `build*` 补上。
String promptDefaultBody(PromptId id) => switch (id) {
  PromptId.p1 => '$p1System\n\n$descRules\n\n$askRules',
  PromptId.p2 => '$p2System\n\n$p2Rules',
  PromptId.p3 => p3System,
  PromptId.p4 => p4System,
};

/// 这条提示词里能用的变量。漏掉任何一个，渲染时都会被换成空串，
/// 也就是提示词里静默少一整段内容。
List<String> promptVars(PromptId id) => switch (id) {
  PromptId.p1 => const <String>['categories', 'locations', 'known'],
  PromptId.p2 => const <String>['categories', 'locations'],
  PromptId.p3 || PromptId.p4 => const <String>[],
};

final class PromptOverride {
  const PromptOverride({required this.text, required this.preset});

  final String text;

  /// 保存时默认正文的哈希，见 [promptPresetHash]。
  final String preset;
}

/// 变化检测用的短哈希（FNV-1a 32 位）。
///
/// 只用来判断「默认正文和我们上次见到的是不是同一版」，不承担安全职责。
String presetHashOf(String text) {
  var hash = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// 当前这一版默认正文的哈希。
String promptPresetHash(PromptId id) => presetHashOf(promptDefaultBody(id));

Map<PromptId, PromptOverride> readPromptOverrides(SqliteDriver db) {
  final raw = asMap(db_settings.getSetting<Object?>(db, SettingsKeys.prompts));
  if (raw == null) return const <PromptId, PromptOverride>{};
  final out = <PromptId, PromptOverride>{};
  raw.forEach((key, value) {
    final id = PromptId.fromWire(key);
    // 别的版本写下的条目（升级又降级的残留）直接忽略
    if (id == null) return;
    final entry = asMap(value);
    final text = entry?['text'];
    if (text is! String || text.trim().isEmpty) return;
    final preset = entry?['preset'];
    out[id] = PromptOverride(
      text: text,
      // 缺哈希时按「与当前默认同版」算：宁可少提示一次，也不要天天喊默认更新了
      preset: preset is String ? preset : promptPresetHash(id),
    );
  });
  return out;
}

/// 用户改过的那份正文；没改过返回 null，调用方回落到默认。
String? readPromptBody(SqliteDriver db, PromptId id) => readPromptOverrides(db)[id]?.text;

void writePromptBody(SqliteDriver db, PromptId id, String text) {
  final all = Map<PromptId, PromptOverride>.of(readPromptOverrides(db));
  final body = text.trim();
  // 写回默认文本等价于恢复默认：不留一条「和默认一模一样」的记录，
  // 否则「已修改」这个状态永远擦不掉。
  if (body == promptDefaultBody(id).trim()) {
    all.remove(id);
  } else {
    all[id] = PromptOverride(text: body, preset: promptPresetHash(id));
  }
  _writeAll(db, all);
}

/// 恢复默认（含「改用新版默认」）。
void resetPromptBody(SqliteDriver db, PromptId id) {
  final all = Map<PromptId, PromptOverride>.of(readPromptOverrides(db))..remove(id);
  _writeAll(db, all);
}

void _writeAll(SqliteDriver db, Map<PromptId, PromptOverride> all) {
  if (all.isEmpty) {
    db_settings.deleteSetting(db, SettingsKeys.prompts);
    return;
  }
  db_settings.setSetting(db, SettingsKeys.prompts, <String, Object?>{
    for (final e in all.entries)
      e.key.wire: <String, Object?>{'text': e.value.text, 'preset': e.value.preset},
  });
}

/// 保存前唯一的检查点。
///
/// 缺变量不会报错，只会被静默换成空串 —— 提示词里少一整段话，
/// 而用户看不出原因，所以必须在这里拦下。
String? validatePromptBody(PromptId id, String text) {
  final body = text.trim();
  if (body.isEmpty) return '提示词不能为空。';
  if (body.length > 20000) return '提示词过长（上限 20000 字）。';
  final allowed = promptVars(id);
  for (final name in allowed) {
    if (!body.contains('{{$name}}')) return '提示词缺少 {{$name}}，它会被替换成对应内容。';
  }
  // 比 render() 的 `\w` 宽：这里要把「写了中文占位符」也拦下来 ——
  // 那种写法 render() 匹配不到，会原样发给模型，用户只会看到提示词里多了一段怪字。
  for (final match in RegExp(r'\{\{([^{}]*)\}\}').allMatches(body)) {
    final name = match.group(1)!;
    if (allowed.contains(name)) continue;
    if (allowed.isEmpty) return '没有 {{$name}} 这个变量，这条提示词不接受变量。';
    return '没有 {{$name}} 这个变量，可用的是 ${allowed.map((v) => '{{$v}}').join('、')}。';
  }
  return null;
}
