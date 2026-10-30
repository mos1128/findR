/// 更新下载控制器 —— 「检查更新 → 选源 → 下载 → 安装」这条链的状态都在这里。
///
/// **为什么是全局常驻的 Notifier**：下载不该被页面导航打断（用户点完「更新」就去干别的了），
/// 进度也要在任何页面都看得见（右下角那个小图标观察的就是这份状态）。所以它不跟任何页面
/// 同生共死 —— 挂在 ProviderScope 上，进程活着它就在。
///
/// 分工（这里**不重写**任何一头的逻辑）：
///   - 拿字节、验真身 → `platform/update.dart`（纯逻辑，可注入假网络）
///   - 拉安装界面、授权页、保活通知 → `platform/update_install.dart`（平台通道）
///   - 这里只决定「什么时候调谁」：状态机 + 进度节流 + 回前台自动续装
library;

import 'dart:async';
import 'dart:io';

import 'package:findr_core/findr_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../platform/update.dart';
import '../platform/update_install.dart';

/// 下载状态 —— 四态（照检查那边的口径：取消/失败/待安装不许混着说）。
sealed class UpdateDownloadState {
  const UpdateDownloadState();
}

/// 「有活干」的三态的共同底座：都带着这次更新对应的版本与渠道。
/// 单独分出这层，是因为界面（小图标）拿到的是基类型，得能直接读 `.info` / `.channel`。
sealed class UpdateTaskState extends UpdateDownloadState {
  const UpdateTaskState({required this.info, required this.channel});

  final UpdateInfo info;
  final UpdateChannel channel;
}

/// 没有下载，也没有下好等着装的东西。
final class UpdateIdle extends UpdateDownloadState {
  const UpdateIdle();
}

final class UpdateDownloading extends UpdateTaskState {
  const UpdateDownloading({
    required super.info,
    required super.channel,
    this.received = 0,
    this.total,
  });

  final int received;
  final int? total;

  /// 0~1；总长未知时为 `null`（界面转圈即可，**别显示假百分比**）。
  double? get fraction => (total == null || total == 0) ? null : received / total!;
}

/// 安装包已就绪（或已下好过一次）。剩下的只有「拉起系统安装界面」。
final class UpdateReady extends UpdateTaskState {
  const UpdateReady({
    required super.info,
    required super.channel,
    required this.file,
    this.needsPermission = false,
    this.prompted = false,
    this.lastInstall,
  });

  final File file;

  /// 系统还没允许本 App「安装未知应用」。卡片据此给「去设置」引导。
  final bool needsPermission;

  /// 已经弹过一次系统安装界面（用户可能自己取消了）—— 回前台时不再自动弹第二次。
  final bool prompted;

  /// 上一次「拉安装界面」的结果。`failed` / `unavailable` 时卡片给浏览器兜底。
  final InstallOutcome? lastInstall;

  UpdateReady copyWith({bool? needsPermission, bool? prompted, InstallOutcome? lastInstall}) => UpdateReady(
    info: info,
    channel: channel,
    file: file,
    needsPermission: needsPermission ?? this.needsPermission,
    prompted: prompted ?? this.prompted,
    lastInstall: lastInstall ?? this.lastInstall,
  );
}

final class UpdateDownloadFailed extends UpdateTaskState {
  const UpdateDownloadFailed({required super.info, required super.channel, required this.reason});

  final String reason;
}

/// 下载用的 HTTP 客户端。测试里换成 `MockClient`（与检查那边同一套路）。
final updateHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// 设备侧动作（安装/授权/保活）。测试里换假实现。
final updatePlatformProvider = Provider<UpdatePlatform>((ref) => const MethodChannelUpdatePlatform());

/// 全局唯一的下载控制器。
final updateDownloadProvider = NotifierProvider<UpdateDownloadNotifier, UpdateDownloadState>(
  UpdateDownloadNotifier.new,
);

final class UpdateDownloadNotifier extends Notifier<UpdateDownloadState> {
  DownloadCancelToken? _cancel;
  bool _disposed = false;

  /// 授权页这次下载只自动递过去一次（用户没开就退回来时，别把设置页反复怼脸；
  /// 卡片上还有「去设置」按钮，那是显式动作）。
  bool _openedSettings = false;

  /// 界面节流：百分比变化 ≥1% 或距上次 ≥300ms 才更新一次状态。
  int _lastUiPercent = -1;
  DateTime _lastUiAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 通知栏节流：每 ≥2% 刷一次（通知不比界面，没必要刷那么勤）。
  int _lastNotifyPercent = -1;

  @override
  UpdateDownloadState build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    // 回前台自动续装：授权页回来、或后台下完回来，都靠这一个时机接上
    final observer = _ResumeRetry(_onResumed);
    WidgetsBinding.instance.addObserver(observer);
    ref.onDispose(() => WidgetsBinding.instance.removeObserver(observer));
    return const UpdateIdle();
  }

  UpdatePlatform get _platform => ref.read(updatePlatformProvider);

  /// 开始下载（或复用已下好的同一版本）。[channel] 是用户在选源弹窗里点出来的那一个。
  Future<void> start({required UpdateInfo info, required UpdateChannel channel}) async {
    // 已经在下的那一份不许被打断 —— 换源重试要先失败退出，这里不抢
    if (state is UpdateDownloading) return;
    _openedSettings = false;
    _lastUiPercent = -1;
    _lastNotifyPercent = -1;
    _lastUiAt = DateTime.fromMillisecondsSinceEpoch(0);

    // 这个版本已经下好过一次（关掉小图标 / 装到一半退出来了）→ 直接进「待安装」。
    // 也让「同版本重试」永远不重下 —— `.apk` 存在本身就等于「这是一份完整的包」。
    final existing = apkFileFor(info.tag);
    if (isCompleteApk(existing)) {
      state = UpdateReady(info: info, channel: channel, file: existing);
      await _autoInstall();
      return;
    }

    final cancel = DownloadCancelToken();
    _cancel = cancel;
    state = UpdateDownloading(info: info, channel: channel);
    await _platform.startKeepAlive('正在下载 Findr 更新 v${info.version}');

    // 主地址失败就试下一个（目前只有 GitHub 有备用地址：加速镜像 → 原站）。
    // **换地址不续传**：不同来源的字节不保证能对上（同 `retryWith` 的口径）。
    final urls = channel.urls;
    DownloadOutcome? outcome;
    for (var i = 0; i < urls.length; i++) {
      if (_disposed || cancel.isCancelled) break;
      if (i > 0) {
        final part = apkPartFileFor(info.tag);
        if (part.existsSync()) part.deleteSync();
        _lastUiPercent = -1;
        _lastNotifyPercent = -1;
      }
      outcome = await downloadApkToFile(
        url: urls[i],
        tag: info.tag,
        client: ref.read(updateHttpClientProvider),
        cancel: cancel,
        onProgress: (received, total) => _onProgress(info, channel, cancel, received, total),
      );
      if (_disposed) return;
      if (outcome is DownloadDone || outcome is DownloadCancelled) break;
    }
    _cancel = null;
    final result = outcome ??
        (cancel.isCancelled ? const DownloadCancelled() : const DownloadFailed('没有可用的下载地址'));

    switch (result) {
      case DownloadDone(:final file):
        await _platform.stopKeepAlive(ready: true);
        if (_disposed) return;
        state = UpdateReady(info: info, channel: channel, file: file);
        await _autoInstall();
      case DownloadCancelled():
        await _platform.stopKeepAlive(ready: false);
        if (_disposed) return;
        state = const UpdateIdle();
      case DownloadFailed(:final reason):
        await _platform.stopKeepAlive(ready: false);
        if (_disposed) return;
        state = UpdateDownloadFailed(info: info, channel: channel, reason: reason);
    }
  }

  void _onProgress(UpdateInfo info, UpdateChannel channel, DownloadCancelToken token, int received, int? total) {
    if (_disposed || _cancel != token) return;
    final now = DateTime.now();
    final percent = (total == null || total == 0) ? null : received * 100 ~/ total;
    if (now.difference(_lastUiAt) >= const Duration(milliseconds: 300) ||
        (percent != null && percent >= _lastUiPercent + 1)) {
      _lastUiAt = now;
      if (percent != null) _lastUiPercent = percent;
      state = UpdateDownloading(info: info, channel: channel, received: received, total: total);
    }
    if (percent != null && percent >= _lastNotifyPercent + 2) {
      _lastNotifyPercent = percent;
      unawaited(_platform.updateKeepAlive(percent));
    }
  }

  /// 拉起系统安装界面。三个入口都走到这里：下载完成（前台时自动）、回前台自动续、
  /// 卡片上的「立即安装」按钮。**只是拉起** —— 装不装、装完没有，系统说了算。
  Future<InstallOutcome> install() async {
    final s = state;
    if (s is! UpdateReady) return InstallOutcome.failed;
    final outcome = await _platform.installApk(s.file.path);
    if (_disposed) return outcome;
    switch (outcome) {
      case InstallOutcome.started:
        state = s.copyWith(prompted: true, needsPermission: false, lastInstall: outcome);
      case InstallOutcome.needPermission:
        state = s.copyWith(needsPermission: true, lastInstall: outcome);
        if (!_openedSettings) {
          _openedSettings = true;
          unawaited(_platform.openInstallSettings());
        }
      case InstallOutcome.failed || InstallOutcome.unavailable:
        state = s.copyWith(needsPermission: false, lastInstall: outcome);
    }
    return outcome;
  }

  /// 下载中取消：`.part` 一并删掉（取消 = 不要了，不是「下次接着下」）。
  void cancel() => _cancel?.cancel();

  /// 失败后原样重试（同源、从 `.part` 续传）。
  Future<void> retry() async {
    final s = state;
    if (s is! UpdateDownloadFailed) return;
    await start(info: s.info, channel: s.channel);
  }

  /// 失败后换一个源重下。**换源不续传** —— 不同来源的字节不保证片段能对上，
  /// 删掉 `.part` 从头下最稳（宁可多下几十兆，也不赌出一个坏包）。
  Future<void> retryWith(UpdateChannel channel) async {
    final s = state;
    if (s is! UpdateDownloadFailed) return;
    final part = apkPartFileFor(s.info.tag);
    if (part.existsSync()) {
      try {
        part.deleteSync();
      } catch (_) {
        // 删不掉就让下载器自己覆盖
      }
    }
    await start(info: s.info, channel: channel);
  }

  /// 关掉小图标（失败不想看了 / 待安装先放着）。
  ///
  /// 下次检查更新再点源会自动续上：已下好的直接进「待安装」，没下完的从 `.part` 续传。
  void dismiss() {
    // 下载中不接「关闭」——那是「取消下载」的位置
    if (state is UpdateDownloading) return;
    state = const UpdateIdle();
    _cancel = null;
  }

  /// 显式打开「安装未知应用」授权页（卡片上的按钮）。与自动那次不同：用户点的，允许再开。
  Future<void> openInstallSettings() => _platform.openInstallSettings();

  /// 前台时立刻拉起安装界面；后台下完就先放着 —— Android 会静默挡掉「后台启动 Activity」，
  /// 硬来只会白费，回前台的时机见 [_onResumed]（通知栏那条「已下载」也是回到这里的入口）。
  Future<void> _autoInstall() async {
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
    await install();
  }

  void _onResumed() {
    if (_disposed) return;
    final s = state;
    if (s is! UpdateReady) return;
    // 授权页回来（needsPermission）或后台下完回来（还没弹过安装界面）→ 自动接上
    if (s.needsPermission || !s.prompted) unawaited(install());
  }
}

/// 只在「回到前台」这一个时机叫醒控制器。
final class _ResumeRetry extends WidgetsBindingObserver {
  _ResumeRetry(this.onResume);

  final VoidCallback onResume;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResume();
  }
}
