/// 「应用内下载更新包」的自动化测试。
///
/// 两条线各测各的：
///   - **下载器**（`lib/platform/update.dart`）：流式落盘、进度、**立刻**取消、断点续传、
///     装前校验（HTML 假页 / 长度不符）、旧包清理 —— 这些在真机上摆不出来，
///     而它们恰恰决定用户遇到的是「重下一次」还是「装错东西」；
///   - **控制器**（`lib/state/update_download.dart`）：状态机、保活开关、
///     回前台自动续装 —— 决定用户看到哪种说法、以及系统安装界面会不会自己弹出来。
///
/// 沙盒钉在临时目录上（同 `device_selfcheck_test.dart` 的路子），网络用 `MockClient` 换掉。
library;

import 'dart:async';
import 'dart:io';

import 'package:findr_app/platform/app_paths.dart';
import 'package:findr_app/platform/update.dart';
import 'package:findr_app/platform/update_install.dart';
import 'package:findr_app/state/update_download.dart';
import 'package:findr_core/findr_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _magic = <int>[0x50, 0x4B, 0x03, 0x04];

/// 一份「像 APK」的字节：ZIP 魔数打头，后面填到 [size]。
List<int> _fakeApk(int size) => <int>[..._magic, ...List<int>.filled(size - _magic.length, 0x2A)];

const _tag = 'v0.2.0+3';

UpdateInfo _info(String tag) {
  final parsed = parseVersionTag(tag)!;
  return UpdateInfo(tag: tag, version: parsed.$1, build: parsed.$2, notes: null, assets: const <UpdateAsset>[]);
}

const _gitee = UpdateChannel(name: 'Gitee', url: 'https://gitee.example/findr.apk');
const _github = UpdateChannel(name: 'GitHub', url: 'https://github.example/findr.apk');

/// 一个分块的响应体。[length] 是**声明**的总长（不一定等于实际发的字节数 ——
/// 「长度不符」那条边界就是这么造出来的）。
http.StreamedResponse _response(
  List<List<int>> chunks, {
  int status = 200,
  int? length,
}) => http.StreamedResponse(
  Stream<List<int>>.fromIterable(chunks),
  status,
  contentLength: length ?? chunks.fold<int>(0, (n, c) => n + c.length),
);

/// 记录调用顺序的假平台。
final class _FakePlatform implements UpdatePlatform {
  final List<String> calls = <String>[];
  InstallOutcome next = InstallOutcome.started;

  @override
  Future<InstallOutcome> installApk(String path) async {
    calls.add('install');
    return next;
  }

  @override
  Future<void> openInstallSettings() async => calls.add('settings');

  @override
  Future<void> startKeepAlive(String title) async => calls.add('keepStart');

  @override
  Future<void> updateKeepAlive(int? percent) async => calls.add('keep:$percent');

  @override
  Future<void> stopKeepAlive({required bool ready}) async => calls.add('keepStop:$ready');
}

ProviderContainer _container(http.Client client, UpdatePlatform platform) {
  final container = ProviderContainer(
    overrides: [
      updateHttpClientProvider.overrideWithValue(client),
      updatePlatformProvider.overrideWithValue(platform),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// 模拟「切走再回来」。[handleAppLifecycleStateChanged] 在状态没变时会早退，
/// 所以先退到 paused 再回 resumed。
void _simulateResume() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  late Directory sandbox;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('findr_update_');
    AppPaths.initWith(sandbox);
    // 控制器挂了生命周期观察者，绑定必须先就位；顺便把 App 置为「在前台」
    TestWidgetsFlutterBinding.ensureInitialized().handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(() {
      AppPaths.resetForTest();
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });
  });

  group('下载器', () {
    test('正常下载：流式落盘、进度到 100%、下完是 .apk 且没有 .part 残留', () async {
      final body = _fakeApk(100);
      final progress = <(int, int?)>[];
      final client = MockClient.streaming(
        (_, _) async => _response(<List<int>>[body.sublist(0, 30), body.sublist(30, 70), body.sublist(70)]),
      );

      final outcome = await downloadApkToFile(
        url: _gitee.url,
        tag: _tag,
        client: client,
        onProgress: (received, total) => progress.add((received, total)),
      );

      expect(outcome, isA<DownloadDone>());
      expect((outcome as DownloadDone).bytes, 100);
      expect(apkFileFor(_tag).readAsBytesSync(), body);
      expect(apkPartFileFor(_tag).existsSync(), isFalse);

      expect(progress.first, (0, 100));
      expect(progress.last, (100, 100));
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i].$1 >= progress[i - 1].$1, isTrue, reason: '进度只能往前走');
      }
    });

    test('取消：数据流卡着也能立刻停，删掉 .part、不出 .apk', () async {
      final gate = StreamController<List<int>>();
      final client = MockClient.streaming(
        (_, _) async => http.StreamedResponse(gate.stream, 200, contentLength: 1000),
      );
      final cancel = DownloadCancelToken();

      final future = downloadApkToFile(url: _gitee.url, tag: _tag, client: client, cancel: cancel);
      gate.add(_fakeApk(16));
      await pumpEventQueue();
      expect(apkPartFileFor(_tag).existsSync(), isTrue, reason: '已经开始写了');

      // 关键：流不再吐数据，取消也必须立刻生效（等不到下一块也不等卡死超时）
      cancel.cancel();
      final outcome = await future;
      expect(outcome, isA<DownloadCancelled>());
      expect(apkPartFileFor(_tag).existsSync(), isFalse, reason: '取消 = 不要了，不留续传的尾巴');
      expect(apkFileFor(_tag).existsSync(), isFalse);
      await gate.close();
    });

    test('取消：连响应头都还没拿到（连接阶段）也要立刻停', () async {
      // 真机上的现象：GitHub 那条跳转链慢，界面上「已下载 0 B、还没开始下」，
      // 这时候点「取消下载」毫无反应 —— 因为 `send()` 拿不到响应头就取消不掉。
      final headerGate = Completer<void>();
      final client = MockClient.streaming((_, _) async {
        await headerGate.future;
        return http.StreamedResponse(const Stream<List<int>>.empty(), 200);
      });
      final cancel = DownloadCancelToken();

      final future = downloadApkToFile(
        url: _gitee.url,
        tag: _tag,
        client: client,
        cancel: cancel,
        responseTimeout: const Duration(seconds: 30),
      );
      await pumpEventQueue();
      cancel.cancel();

      // 不等那 30 秒的连接超时，取消必须马上返回
      final outcome = await future.timeout(const Duration(seconds: 2));
      expect(outcome, isA<DownloadCancelled>());
      expect(apkPartFileFor(_tag).existsSync(), isFalse);
      expect(apkFileFor(_tag).existsSync(), isFalse);
      headerGate.complete();
    });

    test('断点续传：已有一半时带 Range 请求，206 接着写、前缀保住', () async {
      final part = apkPartFileFor(_tag);
      part.writeAsBytesSync(<int>[..._magic, 1, 1]);

      String? range;
      final tail = List<int>.filled(4, 7);
      final client = MockClient.streaming((request, _) async {
        range = request.headers['Range'] ?? request.headers['range'];
        return _response(<List<int>>[tail], status: 206);
      });

      final outcome = await downloadApkToFile(url: _gitee.url, tag: _tag, client: client);
      expect(range, 'bytes=6-');
      expect(outcome, isA<DownloadDone>());
      final bytes = apkFileFor(_tag).readAsBytesSync();
      expect(bytes.length, 10);
      expect(bytes.sublist(0, 4), _magic, reason: '续传不能把已有前缀冲掉');
    });

    test('服务器不支持 Range（回 200）：截断重下，不拼出四不像', () async {
      final part = apkPartFileFor(_tag);
      part.writeAsBytesSync(<int>[..._magic, 1, 1]);

      final full = _fakeApk(10);
      final client = MockClient.streaming((_, _) async => _response(<List<int>>[full]));
      final outcome = await downloadApkToFile(url: _gitee.url, tag: _tag, client: client);

      expect(outcome, isA<DownloadDone>());
      expect(apkFileFor(_tag).readAsBytesSync(), full);
    });

    test('416：本地 .part 已不可信，删掉重来', () async {
      apkPartFileFor(_tag).writeAsBytesSync(<int>[..._magic, 1]);
      final client = MockClient.streaming((_, _) async => _response(const <List<int>>[], status: 416));

      final outcome = await downloadApkToFile(url: _gitee.url, tag: _tag, client: client);
      expect(outcome, isA<DownloadFailed>());
      expect(apkPartFileFor(_tag).existsSync(), isFalse);
    });

    test('下到 HTML 错误页：魔数挡住，删掉那份垃圾', () async {
      final html = '<html>抱歉，访问过于频繁</html>'.codeUnits;
      final client = MockClient.streaming((_, _) async => _response(<List<int>>[html]));

      final outcome = await downloadApkToFile(url: _gitee.url, tag: _tag, client: client);
      expect(outcome, isA<DownloadFailed>());
      expect((outcome as DownloadFailed).reason, contains('不是安装包'));
      expect(apkPartFileFor(_tag).existsSync(), isFalse);
      expect(apkFileFor(_tag).existsSync(), isFalse);
    });

    test('长度不符：不把「传了一半」当成功，.part 留着供续传', () async {
      final client = MockClient.streaming((_, _) async => _response(<List<int>>[_fakeApk(20)], length: 1000));

      final outcome = await downloadApkToFile(url: _gitee.url, tag: _tag, client: client);
      expect(outcome, isA<DownloadFailed>());
      expect((outcome as DownloadFailed).reason, contains('不完整'));
      expect(apkPartFileFor(_tag).existsSync(), isTrue);
    });

    test('非 200/206：直接失败，并说清 HTTP 码', () async {
      final client = MockClient.streaming((_, _) async => _response(const <List<int>>[], status: 404));
      final outcome = await downloadApkToFile(url: _gitee.url, tag: _tag, client: client);
      expect(outcome, isA<DownloadFailed>());
      expect((outcome as DownloadFailed).reason, contains('404'));
    });

    test('清理：只留当前 tag，旧版本的成品与半成品都删掉', () async {
      apkFileFor('v0.1.0+1').writeAsBytesSync(_fakeApk(8));
      apkPartFileFor('v0.1.0+1').writeAsBytesSync(<int>[..._magic, 1]);
      apkFileFor(_tag).writeAsBytesSync(_fakeApk(8)); // 本 tag 的旧成品会先被清掉再重下

      final body = _fakeApk(20);
      final client = MockClient.streaming((_, _) async => _response(<List<int>>[body]));
      final outcome = await downloadApkToFile(url: _gitee.url, tag: _tag, client: client);

      expect(outcome, isA<DownloadDone>());
      expect(apkFileFor('v0.1.0+1').existsSync(), isFalse);
      expect(apkPartFileFor('v0.1.0+1').existsSync(), isFalse);
      expect(apkFileFor(_tag).readAsBytesSync(), body);
    });
  });

  group('控制器', () {
    test('同版本已经下好过：直接进「待安装」，不重下、不开保活', () async {
      apkFileFor(_tag).writeAsBytesSync(_fakeApk(64));
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('', 200);
      });
      final platform = _FakePlatform();
      final container = _container(client, platform);

      await container.read(updateDownloadProvider.notifier).start(info: _info(_tag), channel: _gitee);

      final state = container.read(updateDownloadProvider);
      expect(state, isA<UpdateReady>());
      expect((state as UpdateReady).prompted, isTrue, reason: '前台看着呢，安装界面应该直接弹出来');
      expect(requests, 0);
      expect(platform.calls, <String>['install']);
    });

    test('成功流：Downloading（带进度）→ Ready；保活开一次停一次，安装界面自动拉一次', () async {
      final body = _fakeApk(100);
      final client = MockClient.streaming(
        (_, _) async => _response(<List<int>>[body.sublist(0, 30), body.sublist(30)]),
      );
      final platform = _FakePlatform();
      final container = _container(client, platform);

      final seen = <UpdateDownloadState>[];
      container.listen(updateDownloadProvider, (_, next) => seen.add(next), fireImmediately: true);

      await container.read(updateDownloadProvider.notifier).start(info: _info(_tag), channel: _gitee);

      final downloading = seen.whereType<UpdateDownloading>().toList();
      expect(downloading, isNotEmpty);
      expect(downloading.last.fraction, 1.0);
      expect(container.read(updateDownloadProvider), isA<UpdateReady>());
      expect(apkFileFor(_tag).existsSync(), isTrue);

      expect(platform.calls.first, 'keepStart');
      expect(platform.calls, contains('keepStop:true'));
      expect(platform.calls.where((c) => c == 'install').length, 1);
    });

    test('失败：进 Failed 并把保活停掉（ready=false），不拉安装', () async {
      final client = MockClient.streaming((_, _) async => _response(const <List<int>>[], status: 500));
      final platform = _FakePlatform();
      final container = _container(client, platform);

      await container.read(updateDownloadProvider.notifier).start(info: _info(_tag), channel: _gitee);

      final state = container.read(updateDownloadProvider);
      expect(state, isA<UpdateDownloadFailed>());
      expect((state as UpdateDownloadFailed).reason, contains('500'));
      expect(platform.calls, <String>['keepStart', 'keepStop:false']);
    });

    test('系统没允许安装：状态带标记、授权页只自动开一次、回前台自动接着装', () async {
      apkFileFor(_tag).writeAsBytesSync(_fakeApk(64));
      final platform = _FakePlatform()..next = InstallOutcome.needPermission;
      final container = _container(MockClient((_) async => http.Response('', 200)), platform);

      // 第一次：拉到安装界面被权限挡住
      await container.read(updateDownloadProvider.notifier).start(info: _info(_tag), channel: _github);
      var state = container.read(updateDownloadProvider) as UpdateReady;
      expect(state.needsPermission, isTrue);
      expect(platform.calls.where((c) => c == 'settings').length, 1, reason: '自动把授权页递过去一次');
      expect(state.prompted, isFalse);

      // 用户没开就退回来了：不再反复怼设置页
      _simulateResume();
      await pumpEventQueue();
      state = container.read(updateDownloadProvider) as UpdateReady;
      expect(platform.calls.where((c) => c == 'settings').length, 1);
      expect(state.needsPermission, isTrue);

      // 这次真的开了 → 回前台应该自动接着装（不用再点一次）
      platform.next = InstallOutcome.started;
      _simulateResume();
      await pumpEventQueue();
      state = container.read(updateDownloadProvider) as UpdateReady;
      expect(state.needsPermission, isFalse);
      expect(state.prompted, isTrue);
      expect(platform.calls.where((c) => c == 'install').length, 3);
    });

    test('换源重试：先删掉 .part 再下（不同来源的字节不赌续传）', () async {
      var call = 0;
      bool? partAtSecond;
      final client = MockClient.streaming((_, _) async {
        call++;
        if (call == 1) {
          // 长度对不上 → Failed，`.part` 留着（这属于「网络类失败」，本该可续传）
          return _response(<List<int>>[_fakeApk(20)], length: 1000);
        }
        partAtSecond = apkPartFileFor(_tag).existsSync();
        return _response(<List<int>>[_fakeApk(64)]);
      });
      final container = _container(client, _FakePlatform());

      await container.read(updateDownloadProvider.notifier).start(info: _info(_tag), channel: _gitee);
      expect(container.read(updateDownloadProvider), isA<UpdateDownloadFailed>());
      expect(apkPartFileFor(_tag).existsSync(), isTrue, reason: '同源失败要留着供续传');

      await container.read(updateDownloadProvider.notifier).retryWith(_github);
      expect(partAtSecond, isFalse, reason: '换源前先把 .part 删干净');
      expect(container.read(updateDownloadProvider), isA<UpdateReady>());
    });
  });
}
