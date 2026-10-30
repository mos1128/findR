/// 启动时静默检查更新（24 小时节流）的自动化测试。
///
/// 钉住的都是「用户看不见但代价明显」的口径：
/// - 24 小时内不重复请求（发布接口按 IP 限流）；
/// - 查不到不写节流时间（断一次网不该让接下来一天都不再查）；
/// - 节流期内只凭上次记下的 tag 判断红点，不能凭印象。
library;

import 'dart:convert';

import 'package:findr_app/state/update_check.dart';
import 'package:findr_core/findr_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

SqliteDriver _db() {
  final db = Sqlite3Driver.openInMemory();
  migrate(db);
  return db;
}

http.Response _release(String tag) => http.Response.bytes(
  utf8.encode(jsonEncode(<String, Object?>{'tag_name': tag, 'prerelease': false, 'assets': <Object>[]})),
  200,
);

/// 记录实际打出去的请求 —— 「24 小时内不请求」这条只能靠数次数验证。
http.Client _client(List<String> hits, {String tag = 'v9.9.9', bool fail = false}) =>
    MockClient((req) async {
      hits.add(req.url.toString());
      if (fail) return http.Response('boom', 500);
      return _release(tag);
    });

void main() {
  late SqliteDriver db;
  setUp(() => db = _db());
  tearDown(() => db.close());

  test('24 小时内不再发请求，直接用上次记下的 tag', () async {
    recordUpdateCheck(db, latestTag: 'v9.9.9');
    final hits = <String>[];
    final tag = await runAutoUpdateCheck(
      db: db,
      currentVersion: '1.0.0',
      currentBuild: 1,
      client: _client(hits),
    );
    expect(tag, 'v9.9.9');
    expect(hits, isEmpty);
  });

  test('24 小时内、上次的 tag 不比本机新 —— 不给红点', () async {
    recordUpdateCheck(db, latestTag: 'v0.9.0');
    final hits = <String>[];
    final tag = await runAutoUpdateCheck(
      db: db,
      currentVersion: '1.0.0',
      currentBuild: 1,
      client: _client(hits),
    );
    expect(tag, isNull);
    expect(hits, isEmpty);
  });

  test('超过 24 小时才发请求；发现新版本写入 tag 与时间', () async {
    setSetting(db, kUpdateCheckAtKey, DateTime.now().subtract(const Duration(hours: 25)).millisecondsSinceEpoch);
    final before = DateTime.now().millisecondsSinceEpoch;
    final hits = <String>[];
    final tag = await runAutoUpdateCheck(
      db: db,
      currentVersion: '1.0.0',
      currentBuild: 1,
      client: _client(hits, tag: 'v2.0.0'),
    );
    expect(tag, 'v2.0.0');
    expect(hits, hasLength(1));
    expect(getSetting<String>(db, kUpdateLatestTagKey), 'v2.0.0');
    expect(getSetting<int>(db, kUpdateCheckAtKey), greaterThanOrEqualTo(before));
  });

  test('超过 24 小时、已是最新 —— 清掉旧 tag', () async {
    setSetting(db, kUpdateCheckAtKey, DateTime.now().subtract(const Duration(hours: 25)).millisecondsSinceEpoch);
    setSetting(db, kUpdateLatestTagKey, 'v9.9.9');
    final tag = await runAutoUpdateCheck(
      db: db,
      currentVersion: '2.0.0',
      currentBuild: 1,
      client: _client(<String>[], tag: 'v2.0.0'),
    );
    expect(tag, isNull);
    expect(getSetting<String>(db, kUpdateLatestTagKey), isNull);
  });

  test('查不到 —— 不写节流时间，下次启动还会再试', () async {
    final oldAt = DateTime.now().subtract(const Duration(hours: 25)).millisecondsSinceEpoch;
    setSetting(db, kUpdateCheckAtKey, oldAt);
    final hits = <String>[];
    final tag = await runAutoUpdateCheck(
      db: db,
      currentVersion: '1.0.0',
      currentBuild: 1,
      client: _client(hits, fail: true),
    );
    expect(tag, isNull);
    // 两个源都试过，都失败
    expect(hits, hasLength(2));
    expect(getSetting<int>(db, kUpdateCheckAtKey), oldAt);
  });
}
