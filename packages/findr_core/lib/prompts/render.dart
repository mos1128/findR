/// 提示词渲染。
///
/// 这一层只做「往模板里注入变量」和「拼装 system / user 消息」，
/// 语义（该说什么、不该说什么）全在 `templates.dart` 的字符串里。
library;

import '../types.dart';
import 'templates.dart';

/// 用 enum 表达 `textOnly`（`off` / `unsupported`），只为编译期少一次拼写事故。
enum TextOnlyMode {
  /// 用户选了「不分析图片」，图片仅作附件保存。
  off,

  /// 当前模型无法接收图片。
  unsupported,
}

/// 把 `{{key}}` 换成 [vars] 里的值，**找不到就换成空串**（不是留着占位符）。
///
/// ⚠️ `\w` 默认是 ASCII 的 `[A-Za-z0-9_]`；
/// 占位符名里别用中文，否则会匹配不上（模板里会原样留着 `{{中文}}`）。
String render(String template, Map<String, String> vars) =>
    template.replaceAllMapped(RegExp(r'\{\{(\w+)\}\}'), (m) => vars[m.group(1)!] ?? '');

String buildP1System({
  required String categories,
  required String locations,
  TextOnlyMode? textOnly,
}) {
  var s = render(p1System, {'categories': categories, 'locations': locations});
  s += '\n\n输出 schema（字段名与类型不得改动）：\n$p1Schema';
  final example = textOnly == null ? p1Fewshot : p1FewshotTextOnly;
  s += '\n\n$descRules\n\n$askRules\n\n示例：\n$example';
  if (textOnly == TextOnlyMode.off) {
    s += '\n\n$p1TextOnlyOff';
  } else if (textOnly == TextOnlyMode.unsupported) {
    s += '\n\n$p1TextOnlyUnsupported';
  }
  return s;
}

String buildP1User(String? transcript) => render(p1User, {
  'transcript': transcript ?? '（本次没有文字输入，请仅根据图片判断。）',
});

/// 把卡片已确认的结构化字段渲染成「既定事实」清单。
String describeCardFields(MemoryCard card) {
  final lines = <String>[];
  void push(String label, String? value) {
    if (value != null && value.isNotEmpty) lines.add('- $label：$value');
  }

  // 这里不推「分类」那一行 —— 它**恒为 no-op**，
  // 两个分支都算不出值（注释写着「分类名由调用方按 id 解析，这里不注入」）。
  // 这里照实不注入，并把那行的意图留在这条注释里。
  push('实体名', card.entity);
  push('位置', card.pathNames);
  push('标签', card.tags?.join('、'));
  push('步骤', card.steps?.map((s) => s.text).join('；'));
  return lines.join('\n');
}

/// 编辑结构化字段后重新生成 desc（需求四「编辑闭环」）。
///
/// 把用户已确认的字段作为既定事实注入，避免模型又按自己的理解改写回去。
/// 设计意图见 `docs/prompt设计.md`「重新生成 desc」；文案权威在本文件。
String buildRegenerateDescUser(MemoryCard card) {
  final base = buildP1User(card.transcript);
  final locked = describeCardFields(card);
  if (locked.isEmpty) return base;
  return '$base\n\n用户已确认以下字段，请视为既定事实，不要改动，只重新生成 desc：\n$locked';
}

String buildP2System({required String categories, required String locations}) {
  final head = render(p2System, {'categories': categories, 'locations': locations});
  return '$head\n\n输出 schema：\n$p2OutputSchema'
      '\n\n规则：\n$p2Rules'
      '\n\n示例：\n$p2Fewshot';
}

String buildP3System() => '$p3System\n\n输出 schema：\n$p3Schema';

String buildP3Input(String query, String snippets) =>
    render(p3InputTemplate, {'query': query, 'snippets': snippets});

String buildP4System() => '$p4System\n\n输出 schema：\n$p4Schema';

String buildP4Input(String query, String scenario, int total, String inventory) =>
    render(p4InputTemplate, {
      'query': query,
      'scenario': scenario,
      'total': '$total',
      'inventory': inventory,
    });

String formatCategoriesForPrompt(List<Category> categories) {
  if (categories.isEmpty) return '（暂无）';
  return categories
      .map((c) => '- ${c.name}${c.description != null ? '：${c.description}' : ''}')
      .join('\n');
}

/// 注入策略：**只注入一二级**（房间 → 家具），三级容器不注入。
///
/// 三级容器（抽屉 / 收纳盒）数量大、名字随意，全注入只会把提示词撑长且稀释重点；
/// 而它们对「东西放在哪」的判断帮助有限 —— 真正承重的是一二级。
String formatLocationsForPrompt(List<LocationNode> locations) {
  if (locations.isEmpty) return '（暂无）';
  final byId = <String, LocationNode>{for (final l in locations) l.id: l};

  String fullPath(LocationNode l) {
    final names = <String>[];
    LocationNode? cur = l;
    while (cur != null) {
      names.insert(0, cur.name);
      final parentId = cur.parentId;
      cur = parentId != null ? byId[parentId] : null;
    }
    return names.join('/');
  }

  int depth(LocationNode l) {
    var d = 0;
    LocationNode? cur = l;
    while (cur?.parentId != null) {
      cur = byId[cur!.parentId!];
      d++;
    }
    return d + 1;
  }

  return locations.where((l) => depth(l) <= 2).map(fullPath).join('\n');
}
