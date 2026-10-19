/// 「更新下载」小图标的界面测试：收起是一枚小胶囊、点开是一张小卡片。
///
/// 顺带钉住两件容易在重构里弄丢的事：
///   1. 它挂在 `MaterialApp.builder` 的那层 Stack 里也能正常渲染（那一层没有 Navigator，
///      Directionality / MediaQuery 也不一定在 —— 缺了得自己兜住）；
///   2. 每个状态给出的按钮就是下一步能做的事（下载中能取消、待安装能安装、失败能换源）。
library;

import 'dart:async';
import 'dart:io';

import 'package:findr_app/platform/app_paths.dart';
import 'package:findr_app/platform/update.dart';
import 'package:findr_app/platform/update_install.dart';
import 'package:findr_app/state/update_download.dart';
import 'package:findr_app/theme/tokens.dart';
import 'package:findr_app/ui/update_pill.dart';
import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _magic = <int>[0x50, 0x4B, 0x03, 0x04];
const _tag = 'v0.2.0+3';

List<int> _fakeApk(int size) => <int>[..._magic, ...List<int>.filled(size - _magic.length, 0x2A)];

UpdateInfo _info() {
  final parsed = parseVersionTag(_tag)!;
  return UpdateInfo(tag: _tag, version: parsed.$1, build: parsed.$2, notes: null, assets: const <UpdateAsset>[]);
}

const _gitee = UpdateChannel(name: 'Gitee', url: 'https://gitee.example/findr.apk');

final class _FakePlatform implements UpdatePlatform {
  InstallOutcome next = InstallOutcome.started;

  @override
  Future<InstallOutcome> installApk(String path) async => next;

  @override
  Future<void> openInstallSettings() async {}

  @override
  Future<void> startKeepAlive(String title) async {}

  @override
  Future<void> updateKeepAlive(int? percent) async {}

  @override
  Future<void> stopKeepAlive({required bool ready}) async {}
}

ProviderContainer _container(http.Client client, {UpdatePlatform? platform}) {
  final container = ProviderContainer(
    overrides: [
      updateHttpClientProvider.overrideWithValue(client),
      updatePlatformProvider.overrideWithValue(platform ?? _FakePlatform()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// 与 `main.dart` 里同构：小图标挂在 builder 的 Stack 上，而不是某一页里。
Widget _app(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: buildFindrTheme(Brightness.light),
    builder: (context, child) => Stack(
      children: <Widget>[
        ?child,
        const UpdateProgressPill(),
      ],
    ),
    home: const Scaffold(body: SizedBox.shrink()),
  ),
);

void main() {
  late Directory sandbox;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('findr_update_pill_');
    AppPaths.initWith(sandbox);
    // 「下载完自动弹安装」只在 App 处于前台时发生（见 state/update_download.dart），
    // 测试里也得先把 App 置成前台，否则测的是另一条路。
    TestWidgetsFlutterBinding.ensureInitialized().handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(() {
      AppPaths.resetForTest();
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });
  });

  testWidgets('没在更新：小图标不出场', (tester) async {
    final container = _container(MockClient((_) async => http.Response('', 200)));
    await tester.pumpWidget(_app(container));
    expect(find.textContaining('下载'), findsNothing);
    expect(find.textContaining('安装'), findsNothing);
  });

  testWidgets('下载中：胶囊报百分比，点开是进度卡片', (tester) async {
    final gate = StreamController<List<int>>();
    final container = _container(
      MockClient.streaming((_, _) async => http.StreamedResponse(gate.stream, 200, contentLength: 100)),
    );
    // ⚠️ 下载要落真实文件（IOSink），必须放 runAsync 的真实异步里跑 ——
    // 在 testWidgets 的假异步区里做真 I/O 会把测试框架卡死。
    // 界面这一侧照常 pump 即可：状态一变，小图标就重建。
    await tester.runAsync(() async {
      unawaited(container.read(updateDownloadProvider.notifier).start(info: _info(), channel: _gitee));
      gate.add(_fakeApk(50));
      for (var i = 0; i < 20 && (container.read(updateDownloadProvider) as UpdateDownloading).received < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });

    await tester.pumpWidget(_app(container));
    await tester.pump();
    expect(find.text('下载中 50%'), findsOneWidget);

    await tester.tap(find.text('下载中 50%'));
    await tester.pump();
    expect(find.text('正在下载更新'), findsOneWidget);
    expect(find.text('取消下载'), findsOneWidget);
    expect(find.text('浏览器下载'), findsOneWidget);

    // 收尾：点到取消，把流与定时器都收干净
    await tester.tap(find.text('取消下载'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await gate.close();
    });
    await tester.pump();
    expect(find.textContaining('下载中'), findsNothing);
  });

  testWidgets('已下载：胶囊提示待安装，卡片给安装与兜底', (tester) async {
    apkFileFor(_tag).writeAsBytesSync(_fakeApk(64));
    final container = _container(MockClient((_) async => http.Response('', 200)));
    await container.read(updateDownloadProvider.notifier).start(info: _info(), channel: _gitee);

    await tester.pumpWidget(_app(container));
    await tester.pump();
    expect(find.text('待安装'), findsOneWidget);

    await tester.tap(find.text('待安装'));
    await tester.pump();
    expect(find.text('更新已下载'), findsOneWidget);
    expect(find.text('立即安装'), findsOneWidget);
    expect(find.text('浏览器下载'), findsOneWidget);
    expect(find.text('暂不安装'), findsOneWidget);
  });

  testWidgets('系统没允许安装：胶囊提示要授权，卡片给「去设置」', (tester) async {
    apkFileFor(_tag).writeAsBytesSync(_fakeApk(64));
    final platform = _FakePlatform()..next = InstallOutcome.needPermission;
    final container = _container(MockClient((_) async => http.Response('', 200)), platform: platform);
    await container.read(updateDownloadProvider.notifier).start(info: _info(), channel: _gitee);

    await tester.pumpWidget(_app(container));
    await tester.pump();
    expect(find.text('需要授权'), findsOneWidget);

    await tester.tap(find.text('需要授权'));
    await tester.pump();
    expect(find.text('需要允许安装'), findsOneWidget);
    expect(find.text('去设置'), findsOneWidget);
    expect(find.textContaining('返回后自动继续'), findsOneWidget);
  });

  testWidgets('下载失败：胶囊变「下载失败」，卡片能续传 / 换源 / 走浏览器', (tester) async {
    final container = _container(
      MockClient.streaming(
        (_, _) async => http.StreamedResponse(const Stream<List<int>>.empty(), 500),
      ),
    );
    await container.read(updateDownloadProvider.notifier).start(info: _info(), channel: _gitee);

    await tester.pumpWidget(_app(container));
    await tester.pump();
    expect(find.text('下载失败'), findsOneWidget);

    await tester.tap(find.text('下载失败'));
    await tester.pump();
    expect(find.text('更新下载失败'), findsOneWidget);
    expect(find.textContaining('500'), findsOneWidget);
    expect(find.text('继续下载'), findsOneWidget);
    expect(find.text('换到 GitHub'), findsOneWidget);
    expect(find.text('浏览器下载'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
  });
}
