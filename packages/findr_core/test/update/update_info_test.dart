import 'package:findr_core/findr_core.dart';
import 'package:test/test.dart';

/// `update/update_info.dart` 的验收网（理由见该文件头）。
///
/// 重点钉四件事：**坏内容一律 null**（一个坏源不许拖垮整轮检查）、
/// **tag 解析只认认识的写法**（旧的滚动 tag 绝不能被当成版本）、
/// **两家接口的形状都能读**（样本取自真实响应）、**版本比较的边界**。
void main() {
  test('解析：GitHub 形状的响应（节选自真实响应）', () {
    const body = '''
{
  "tag_name": "v0.2.0+3",
  "name": "Findr 开发版 · Flutter · v0.2.0+3",
  "draft": false,
  "prerelease": false,
  "body": "  - 修了几个问题  ",
  "assets": [
    {"name": "app-release.apk", "browser_download_url": "https://github.com/mos1128/findR/releases/download/v0.2.0+3/app-release.apk"}
  ]
}
''';
    final info = parseReleaseInfo(body)!;
    expect(info.tag, 'v0.2.0+3');
    expect(info.version, '0.2.0');
    expect(info.build, 3);
    expect(info.notes, '- 修了几个问题', reason: '两侧空白应裁掉');
    expect(info.assets.single.name, 'app-release.apk');
    expect(info.assets.single.url, contains('github.com'));
  });

  test('解析：Gitee 形状的响应（含它自动带的源码包，也要能读）', () {
    const body = '''
{
  "id": 593237,
  "tag_name": "v0.2.0+3",
  "prerelease": false,
  "name": "Findr 开发版",
  "body": "本次更新：\\n- 检查更新改读接口",
  "created_at": "2026-10-10T12:00:00+08:00",
  "assets": [
    {"name": "v0.2.0+3.zip", "browser_download_url": "https://gitee.com/ms6/findR/archive/refs/tags/v0.2.0+3.zip"},
    {"name": "app-release.apk", "browser_download_url": "https://gitee.com/ms6/findR/releases/download/v0.2.0+3/app-release.apk"}
  ]
}
''';
    final info = parseReleaseInfo(body)!;
    expect(info.version, '0.2.0');
    expect(info.build, 3);
    expect(info.notes, contains('检查更新改读接口'));
    expect(info.assets.map((a) => a.name), ['v0.2.0+3.zip', 'app-release.apk']);
  });

  test('解析：坏内容一律 null（一个坏源不许拖垮整轮检查）', () {
    for (final bad in <String>[
      '',
      '   ',
      '<html>404 Not Found</html>',
      '{"message":"404 Not Found"}',
      '{"message":"rate limit exceeded"}',
      '{"tag_name":""}',
      '{"tag_name":123}',
      '{"name":"v1.0.0"}',
      '[1, 2, 3]',
      '"just a string"',
      'null',
      // 旧发布用的滚动 tag：认不出数字版本 ⇒ 当这一路没有数据
      '{"tag_name":"flutter-dev-latest","body":"旧发布"}',
      '{"tag_name":"dev-latest"}',
    ]) {
      expect(parseReleaseInfo(bad), isNull, reason: '输入：$bad');
    }
  });

  test('解析：assets 里的坏条目逐条跳过，不牵连整份', () {
    const body = '''
{
  "tag_name": "v1.0.0",
  "assets": [
    {"name": "ok.apk", "browser_download_url": "https://a.example/ok.apk"},
    {"name": "no-url"},
    {"name": "bad.apk", "browser_download_url": "javascript:alert(1)"},
    "not a map",
    {"name": "  ", "browser_download_url": "https://b.example/x"},
    {"name": "trim.apk", "browser_download_url": "  https://c.example/trim.apk  "}
  ]
}
''';
    final info = parseReleaseInfo(body)!;
    expect(info.assets.map((a) => a.name), ['ok.apk', 'trim.apk']);
    expect(info.assets.last.url, 'https://c.example/trim.apk');
  });

  test('tag 解析：认 `v` 前缀、`+` 与 `-` 两种构建号；认不出来就是 null', () {
    expect(parseVersionTag('v0.1.0+1'), ('0.1.0', 1));
    expect(parseVersionTag('0.1.0+2'), ('0.1.0', 2));
    expect(parseVersionTag('v0.2.0'), ('0.2.0', 0));
    expect(parseVersionTag('V1.0'), ('1.0', 0));
    expect(parseVersionTag('v0.1.0-3'), ('0.1.0', 3));
    expect(parseVersionTag('v0.1.0+'), ('0.1.0', 0), reason: '空构建号按 0');
    // 认不出来的不猜
    expect(parseVersionTag('flutter-dev-latest'), isNull);
    expect(parseVersionTag('v0.1.0-rc1'), isNull, reason: '别把 rc1 当构建号');
    expect(parseVersionTag(''), isNull);
    expect(parseVersionTag('v'), isNull);
    expect(parseVersionTag('latest'), isNull);
  });

  test('比较：相等 / 大小 / 缺位 / v 前缀 / +构建号尾巴 / 数字不是字符串', () {
    expect(compareVersions('0.1.0', '0.1.0'), 0);
    expect(compareVersions('1.0', '1.0.0'), 0, reason: '缺位按 0 处理');
    expect(compareVersions('0.2.0', '0.1.9'), greaterThan(0));
    expect(compareVersions('0.1.9', '0.2.0'), lessThan(0));
    expect(compareVersions('v0.2.0', '0.1.0'), greaterThan(0));
    expect(compareVersions('0.1.0+4', '0.1.0'), 0, reason: '+构建号不参与版本比较');
    expect(compareVersions('10.0.0', '9.9.9'), greaterThan(0), reason: '别按字符串比');
    expect(compareVersions('', '0.0.0'), 0);
  });

  test('isNewerThan：版本号优先，同版本看构建号', () {
    final newer = parseReleaseInfo('{"tag_name":"v0.2.0"}')!;
    expect(isNewerThan(newer, currentVersion: '0.1.0', currentBuild: 9), isTrue);

    final sameBuild = parseReleaseInfo('{"tag_name":"v0.1.0+3"}')!;
    expect(isNewerThan(sameBuild, currentVersion: '0.1.0', currentBuild: 3), isFalse);
    expect(isNewerThan(sameBuild, currentVersion: '0.1.0', currentBuild: 2), isTrue);

    final older = parseReleaseInfo('{"tag_name":"v0.0.9+99"}')!;
    expect(isNewerThan(older, currentVersion: '0.1.0', currentBuild: 0), isFalse,
        reason: '构建号再大也盖不过版本号');

    // 当前发版约定：版本号就是三段 `X.Y.Z`（不带 `+N`，Android 的 versionCode 固定是 1），
    // **最后一位加一就算新版**。这条是整个「检查更新」的地基，别改坏。
    final patchBump = parseReleaseInfo('{"tag_name":"v1.0.1"}')!;
    expect(isNewerThan(patchBump, currentVersion: '1.0.0', currentBuild: 1), isTrue);
    expect(isNewerThan(parseReleaseInfo('{"tag_name":"v1.0.10"}')!, currentVersion: '1.0.9', currentBuild: 1),
        isTrue,
        reason: '按数字比，不是按字符串比');
    final sameVersion = parseReleaseInfo('{"tag_name":"v1.0.0"}')!;
    expect(isNewerThan(sameVersion, currentVersion: '1.0.0', currentBuild: 1), isFalse,
        reason: '同版本号重发包发现不了 ⇒ 要发版就得把最后一位加一');
  });
}
