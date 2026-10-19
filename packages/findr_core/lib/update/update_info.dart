/// 更新信息（发布接口返回的那份 release）的解析与版本比较 —— **纯逻辑，不出网**。
///
/// **版本号从哪来：发布 tag。** 发布约定是「一版一 tag」，tag 就是 `v` + pubspec 的版本号
/// （`1.0.1` → `v1.0.1`）—— App 只认 tag，不需要额外的文件。
/// 代价是**每次发版必须让 pubspec 的版本号发生变化**：版本号是三段 `X.Y.Z`，
/// **每发一版把最后一位加一**，否则 tag 不变 —— 那就没有「新版本」可言了。
/// tag 里若带了 `+构建号`（老写法）也照样认，见 [parseVersionTag]。
///
/// **解析一律宽容**：Gitee 与 GitHub 两家的接口字段基本对齐（`tag_name` / `body` / `assets`），
/// 但错误响应（`{"message":"404 Not Found"}`）、HTML、限流提示也会走到这里 ——
/// 一律返回 `null`，由调用方按「这一路不通」处理、换下一路。
library;

import 'dart:convert';

/// release 里挂的一个附件（我们只关心名字和下载地址）。
final class UpdateAsset {
  const UpdateAsset({required this.name, required this.url});

  final String name;
  final String url;
}

/// 一次发布里我们关心的那几样。
final class UpdateInfo {
  const UpdateInfo({
    required this.tag,
    required this.version,
    required this.build,
    required this.notes,
    required this.assets,
  });

  /// 原始 tag（下载地址按它拼），例如 `v1.0.1`。
  final String tag;

  /// 从 tag 解析出的版本号（`1.0.1`）。
  final String version;

  /// 从 tag 解析出的构建号；tag 里没写就按 0。
  final int build;

  /// 发布说明（接口里的 `body`）。可空。
  final String? notes;

  /// 该 release 挂的附件。**Gitee 会把自己的源码包（zip / tar.gz）也列在这里**，
  /// 所以要按名字挑，不能拿到第一个就用。
  final List<UpdateAsset> assets;
}

/// 解析 release 接口的响应体。坏内容一律 `null`（理由见文件头）。
UpdateInfo? parseReleaseInfo(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;

  final rawTag = decoded['tag_name'];
  if (rawTag is! String || rawTag.trim().isEmpty) return null;
  final tag = rawTag.trim();
  final parsed = parseVersionTag(tag);
  if (parsed == null) return null;

  final rawBody = decoded['body'];
  final assets = <UpdateAsset>[];
  final rawAssets = decoded['assets'];
  if (rawAssets is List) {
    for (final item in rawAssets) {
      if (item is! Map) continue;
      final name = item['name'];
      final url = item['browser_download_url'];
      if (name is! String || url is! String) continue;
      final trimmedUrl = url.trim();
      // 只收 http(s) —— 免得把 javascript: / file: 之类当成下载入口
      if (name.trim().isEmpty || !trimmedUrl.startsWith('http')) continue;
      assets.add(UpdateAsset(name: name.trim(), url: trimmedUrl));
    }
  }

  return UpdateInfo(
    tag: tag,
    version: parsed.$1,
    build: parsed.$2,
    notes: rawBody is String && rawBody.trim().isNotEmpty ? rawBody.trim() : null,
    assets: assets,
  );
}

/// 从 tag 里取出「版本号 + 构建号」。取不出来返回 `null` —— 那一路的数据就当没有。
///
/// 认三种写法：`v0.2.0`（没有构建号）、`v0.2.0+3`（pubspec 的写法，CI 用的就是这个）、
/// `v0.2.0-3`（万一以后要换分隔符）。**认不出来的绝不猜**：旧发布用的滚动 tag
/// （`flutter-dev-latest`）在这里返回 `null`，于是它不会被当成一个合法版本。
(String, int)? parseVersionTag(String tag) {
  var t = tag.trim().replaceFirst(RegExp(r'^[vV]'), '');
  if (t.isEmpty) return null;

  var build = 0;
  final plus = t.indexOf('+');
  if (plus >= 0) {
    build = int.tryParse(t.substring(plus + 1).trim()) ?? 0;
    t = t.substring(0, plus);
  } else {
    // `-` 只在后半段是纯数字时才算构建号 —— 别把 `0.1.0-rc1` 读成构建号 1
    final dash = t.lastIndexOf('-');
    final tail = dash > 0 ? t.substring(dash + 1).trim() : '';
    if (dash > 0 && int.tryParse(tail) != null) {
      build = int.parse(tail);
      t = t.substring(0, dash);
    }
  }

  final version = t.trim();
  if (version.isEmpty || !RegExp(r'^\d+(\.\d+)*$').hasMatch(version)) return null;
  return (version, build);
}

/// 发布正文里**只该给 App 看**的那一段。
///
/// 约定：正文里单独一行的 `---` 之后是**给网页读者**的安装须知（签名、自检、备份明文这些），
/// 更新弹窗不该显示它们 —— 否则用户点开更新看到的是"包名 com.findr.app.dev"和一堆免责说明，
/// 既占地方又要跟着版本维护（0.0.2 那次就有一条"当前沿用 debug 签名"过期了）。
/// 拼正文的那一侧在 `.github/workflows/flutter.yml`（组装发布正文那步），两边靠这条约定对齐。
///
/// 没有 `---` 就整段都算说明；切完是空的则返回 `null`（调用方显示"暂无更新说明"）。
String? releaseNotesForApp(String? body) {
  if (body == null) return null;
  final head = <String>[];
  for (final line in body.split('\n')) {
    if (line.trim() == '---' || line.trim() == '***') break;
    head.add(line);
  }
  final text = head.join('\n').trim();
  return text.isEmpty ? null : text;
}

/// 比较两段版本号（点分数字段，容忍 `v` 前缀与 `+构建号` 尾巴）。
///
/// 返回 `>0` 表示 [a] 新于 [b]，`0` 表示相等，`<0` 表示 [a] 旧于 [b]。
/// **缺位按 0 处理** ⇒ `1.0` 与 `1.0.0` 相等；段里混进非数字的（`0-rc1`）
/// 只取其数字部分 —— 我们自己的版本号不用预发布后缀，这里只为不崩。
int compareVersions(String a, String b) {
  final pa = _versionParts(a);
  final pb = _versionParts(b);
  final len = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < len; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x > y ? 1 : -1;
  }
  return 0;
}

/// 远端是否新于本机。版本号相同看构建号 —— 「同版本重出一次包」也得能发现。
bool isNewerThan(
  UpdateInfo remote, {
  required String currentVersion,
  required int currentBuild,
}) {
  final cmp = compareVersions(remote.version, currentVersion);
  if (cmp != 0) return cmp > 0;
  return remote.build > currentBuild;
}

List<int> _versionParts(String v) {
  final core = v.trim().replaceFirst(RegExp(r'^[vV]'), '').split('+').first;
  return core
      .split('.')
      .map((s) => int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .toList();
}
