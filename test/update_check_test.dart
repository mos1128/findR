/// 「检查更新」顺序取源逻辑的自动化测试（`lib/platform/update.dart`）。
///
/// 存在的理由：这套逻辑的价值全在**顺序与边界**上 —— 先问谁、谁坏了换谁、
/// 什么时候**不该**再问第二家、内容不认识时怎么退。这些在真机上摆不出来，
/// 而它们恰恰决定了用户看到哪种说法、以及一共发了几个请求。
///
/// 用 `MockClient` 把整条网络换掉，并记录**实际打出去的请求**（顺序与次数都要钉住）。
library;

import 'dart:convert';

import 'package:findr_app/platform/update.dart';
import 'package:findr_app/state/update_check.dart';
import 'package:findr_core/findr_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _gitee = 'https://gitee.example/api/v5/repos/ms6/findR/releases/latest';
const _github = 'https://api.example/repos/mos1128/findR/releases/latest';

/// 真响应长这样：JSON 是 UTF-8 字节，响应头里没有 charset。
http.Response _json(String body) => http.Response.bytes(utf8.encode(body), 200);

String _release({
  required String tag,
  String? notes,
  List<Map<String, String>> assets = const <Map<String, String>>[],
}) {
  return jsonEncode(<String, Object?>{
    'tag_name': tag,
    'name': 'Findr 开发版 · $tag',
    'prerelease': false,
    // 多出来的字段一律被忽略 —— 两家接口的字段不完全一样，别依赖它们
    'created_at': '2026-10-10T12:00:00+08:00',
    'body': ?notes,
    'assets': assets,
  });
}

Future<UpdateCheckResult> _run(
  http.Client client, {
  String currentVersion = '0.1.0',
  int currentBuild = 1,
  List<String> sources = const <String>[_gitee, _github],
}) {
  return checkForUpdate(
    currentVersion: currentVersion,
    currentBuild: currentBuild,
    sources: sources,
    client: client,
    timeout: const Duration(seconds: 2),
  );
}

void main() {
  test('先问 Gitee：它给了结果就不再打扰 GitHub（一次检查只发一个请求）', () async {
    final calls = <String>[];
    final client = MockClient((req) async {
      calls.add(req.url.toString());
      if (req.url.toString() == _gitee) return _json(_release(tag: 'v0.2.0+1', notes: '改了两处'));
      return _json(_release(tag: 'v9.9.9'));
    });

    final res = await _run(client);
    expect(res, isA<UpdateAvailable>());
    expect((res as UpdateAvailable).info.version, '0.2.0');
    expect(calls, <String>[_gitee], reason: '顺序方案：Gitee 通了就不问 GitHub');
  });

  test('Gitee 不通（404 / 500 / 断网）时，GitHub 兜底', () async {
    for (final broken in <http.Response Function()>[
      () => http.Response('{"message":"404 Not Found"}', 404),
      () => http.Response('boom', 500),
      () => throw StateError('连接被重置'),
    ]) {
      final calls = <String>[];
      final client = MockClient((req) async {
        calls.add(req.url.toString());
        if (req.url.toString() == _gitee) return broken();
        return _json(_release(tag: 'v0.2.0+1'));
      });
      final res = await _run(client);
      expect(res, isA<UpdateAvailable>(), reason: 'Gitee 坏了就该落到 GitHub');
      expect(calls, <String>[_gitee, _github]);
    }
  });

  test('Gitee 说「已是最新」时同样不再问 GitHub（这就是顺序方案的定义）', () async {
    final calls = <String>[];
    final client = MockClient((req) async {
      calls.add(req.url.toString());
      return _json(_release(tag: 'v0.1.0+1'));
    });

    final res = await _run(client);
    expect(res, isA<UpToDate>());
    expect(calls, <String>[_gitee]);
  });

  test('所有源都不通 → CheckFailed（不许说成「已是最新」）', () async {
    final calls = <String>[];
    final client = MockClient((req) async {
      calls.add(req.url.toString());
      return req.url.toString() == _gitee
          ? http.Response('<html>人机验证</html>', 200)
          : http.Response('{"message":"rate limit exceeded"}', 403);
    });

    final res = await _run(client);
    expect(res, isA<UpdateCheckFailed>());
    expect(calls, <String>[_gitee, _github], reason: '每一路都要试过才算「查不到」');
  });

  test('中文发布说明不乱码（响应头不带 charset，按字节解 UTF-8）', () async {
    final client = MockClient((_) async => _json(_release(tag: 'v0.2.0+1', notes: '改了两个地方，试试看 🎒')));
    final res = await _run(client);
    expect((res as UpdateAvailable).info.notes, '改了两个地方，试试看 🎒');
  });

  test('请求带上 User-Agent（GitHub 接口缺 UA 会直接 403）', () async {
    String? ua;
    final client = MockClient((req) async {
      ua = req.headers['User-Agent'] ?? req.headers['user-agent'];
      return _json(_release(tag: 'v0.2.0+1'));
    });
    await _run(client);
    expect(ua, 'findr-app');
  });

  test('下载渠道：优先用发布里挂的附件地址，缺了就按 tag 拼（tag 里的 + 要编码）', () {
    final withAssets = parseReleaseInfo(
      _release(
        tag: 'v0.2.0+1',
        assets: <Map<String, String>>[
          <String, String>{
            'name': 'app-release.apk',
            'browser_download_url':
                'https://gitee.com/ms6/findR/releases/download/v0.2.0+1/app-release.apk',
          },
        ],
      ),
    )!;
    final channels = downloadChannels(withAssets, accelPrefix: kUpdateAccelPrefixDefault);
    expect(channels.map((c) => c.name), <String>['Gitee', 'GitHub']);
    expect(channels[0].url, contains('gitee.com'), reason: 'Gitee 在前');
    expect(channels[0].url, endsWith('/v0.2.0+1/app-release.apk'), reason: '用附件给的地址');
    expect(channels[1].url, startsWith(kUpdateAccelPrefixDefault), reason: 'GitHub 先走加速镜像');
    expect(channels[1].url, endsWith('https://github.com/mos1128/findR/releases/download/v0.2.0%2B1/app-release.apk'));
    expect(channels[1].fallbackUrls, hasLength(1), reason: '镜像失败自动回原站');

    final noAssets = parseReleaseInfo(_release(tag: 'v0.2.0+1'))!;
    final built = downloadChannels(noAssets, accelPrefix: kUpdateAccelPrefixDefault);
    expect(built[0].url, 'https://gitee.com/ms6/findR/releases/download/v0.2.0%2B1/app-release.apk');
    expect(built[1].url,
        '${kUpdateAccelPrefixDefault}https://github.com/mos1128/findR/releases/download/v0.2.0%2B1/app-release.apk');
    expect(built[1].fallbackUrls.single,
        'https://github.com/mos1128/findR/releases/download/v0.2.0%2B1/app-release.apk');

    // 加速关闭（不传前缀）时直接走原站，也不该有回退地址
    final plain = downloadChannels(noAssets);
    expect(plain[1].url, 'https://github.com/mos1128/findR/releases/download/v0.2.0%2B1/app-release.apk');
    expect(plain[1].fallbackUrls, isEmpty);
  });

  test('长按下载按钮打开的是发布页（releases 列表），不是 APK 直链', () {
    expect(
      releasePageFor(const UpdateChannel(name: 'Gitee', url: 'https://x')),
      'https://gitee.com/ms6/findR/releases',
    );
    expect(
      releasePageFor(const UpdateChannel(name: 'GitHub', url: 'https://x')),
      'https://github.com/mos1128/findR/releases',
    );
  });
}
