/// 全局「更新进度」小图标 —— 悬浮在所有页面之上，可缩成一个胶囊、点开成一张小卡片。
///
/// **为什么挂在 MaterialApp.builder 的 Stack 里**（见 `main.dart`）：下载是从设置页发起的，
/// 但用户点完就会去干别的 —— 小图标必须活在**所有路由之上**，挂 `home` 会被 push 出来的
/// 设置页盖住。它自身不弹任何对话框（builder 这一层没有 Navigator），
/// 展开、按钮、提示全在一张小卡片里就地完成 —— 也就不可能挡住任何其他功能。
///
/// 它只做一件事：把 `state/update_download.dart` 的状态画出来，并把按钮点进控制器。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../platform/update.dart';
import '../platform/update_install.dart';
import '../state/update_download.dart';
import '../theme/tokens.dart';

class UpdateProgressPill extends ConsumerStatefulWidget {
  const UpdateProgressPill({super.key});

  @override
  ConsumerState<UpdateProgressPill> createState() => _UpdateProgressPillState();
}

class _UpdateProgressPillState extends ConsumerState<UpdateProgressPill> {
  bool _expanded = false;

  /// 就地提示（比如浏览器拉不起来）。**不弹 toast** —— 这一层没有 ScaffoldMessenger。
  String? _note;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(updateDownloadProvider);
    // 没在下载、也没下好/失败的东西：不出场
    if (state is! UpdateTaskState) return const SizedBox.shrink();
    final c = FindrColors.of(context);
    return Positioned(
      right: Spacing.four,
      // 抬到首页录入坞之上（那一坞大约 120 高）
      bottom: Spacing.six + 72,
      child: _maybeDirectionality(
        context,
        _expanded ? _card(context, c, state) : _chip(context, c, state),
      ),
    );
  }

  /// builder 那一层不一定有 Directionality（widget 测试一跑就知道）——缺了就地补一个。
  /// 本 App 只有中文，ltr 永远是对的。
  Widget _maybeDirectionality(BuildContext context, Widget child) {
    if (Directionality.maybeOf(context) != null) return child;
    return Directionality(textDirection: TextDirection.ltr, child: child);
  }

  void _toggle() {
    setState(() {
      _expanded = !_expanded;
      _note = null;
    });
  }

  // ── 收起态：一枚小胶囊 ─────────────────────────────────────────

  Widget _chip(BuildContext context, FindrColors c, UpdateTaskState state) {
    final (Widget leading, String label) = switch (state) {
      UpdateDownloading(:final fraction) => (
        SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(value: fraction, strokeWidth: 2.2, color: c.record),
        ),
        fraction == null ? '下载中…' : '下载中 ${(fraction * 100).round()}%',
      ),
      UpdateReady(:final needsPermission) => (
        Icon(Icons.system_update_alt_rounded, size: 18, color: c.record),
        needsPermission ? '需要授权' : '待安装',
      ),
      UpdateDownloadFailed() => (Icon(Icons.error_outline_rounded, size: 18, color: c.danger), '下载失败'),
    };
    // ⚠️ 一块「浮在页面上」的东西必须看得出来是浮着的：比卡片面（surface）**再亮一档**、
    //    描一圈边、投影加重。用 surface 时它和设置页的卡片几乎同色，用户会以为那行字是
    //    页面的一部分（真机反馈："和背景有点不好区分"）。
    return Material(
      color: c.surfaceAlt,
      elevation: 8,
      shadowColor: c.shadow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.pill),
        side: BorderSide(color: c.borderStrong),
      ),
      child: InkWell(
        onTap: _toggle,
        borderRadius: BorderRadius.circular(Radii.pill),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.three, vertical: Spacing.two + 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              leading,
              const SizedBox(width: Spacing.two),
              Text(
                label,
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.text),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 展开态：一张小卡片 ─────────────────────────────────────────

  Widget _card(BuildContext context, FindrColors c, UpdateTaskState state) {
    return Material(
      color: c.surfaceAlt,
      elevation: 12,
      shadowColor: c.shadow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
        side: BorderSide(color: c.borderStrong),
      ),
      child: Container(
        width: 272,
        padding: const EdgeInsets.all(Spacing.four),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    _title(state),
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: c.text),
                  ),
                ),
                GestureDetector(
                  onTap: _toggle,
                  child: Icon(Icons.expand_more_rounded, size: 18, color: c.textMuted),
                ),
              ],
            ),
            const SizedBox(height: Spacing.two),
            Text(
              '更新 ${state.info.version} · 来源 ${state.channel.name}',
              style: TextStyle(fontSize: 11.5, color: c.textMuted),
            ),
            const SizedBox(height: Spacing.three),
            ..._body(context, c, state),
            if (_note != null) ...<Widget>[
              const SizedBox(height: Spacing.three),
              Text(_note!, style: TextStyle(fontSize: 11.5, height: 1.4, color: c.danger)),
            ],
          ],
        ),
      ),
    );
  }

  String _title(UpdateTaskState state) => switch (state) {
    UpdateDownloading() => '正在下载更新',
    UpdateReady(:final needsPermission) => needsPermission ? '需要允许安装' : '更新已下载',
    UpdateDownloadFailed() => '更新下载失败',
  };

  List<Widget> _body(BuildContext context, FindrColors c, UpdateTaskState state) {
    switch (state) {
      case UpdateDownloading(:final fraction, :final received, :final total):
        return <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.xs),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 6,
              backgroundColor: c.surfaceAlt,
              color: c.record,
            ),
          ),
          const SizedBox(height: Spacing.two),
          Text(
            total == null ? '已下载 ${_fmtBytes(received)}' : '${_fmtBytes(received)} / ${_fmtBytes(total)}',
            style: TextStyle(fontSize: 11.5, color: c.textSecondary),
          ),
          const SizedBox(height: Spacing.three),
          _buttons(<Widget>[
            _action(c, '取消下载', () => ref.read(updateDownloadProvider.notifier).cancel()),
            _ghost(c, '浏览器下载', () => _openBrowser(state)),
          ]),
        ];
      case UpdateReady(:final needsPermission, :final lastInstall, :final file):
        return <Widget>[
          Text(
            needsPermission
                ? '系统还没允许 Findr 安装应用。点「去设置」打开开关，返回后会自动继续安装。'
                : lastInstall == InstallOutcome.unavailable || lastInstall == InstallOutcome.failed
                    ? '这台设备上拉不起系统安装界面，请用浏览器下载后手动安装。'
                    : '安装包已下载好（${_fileSize(file)}）。安装时直接覆盖安装（别卸载），本地数据不会丢。',
            style: TextStyle(fontSize: 12, height: 1.45, color: c.textSecondary),
          ),
          const SizedBox(height: Spacing.three),
          _buttons(<Widget>[
            if (needsPermission)
              _action(c, '去设置', () => ref.read(updateDownloadProvider.notifier).openInstallSettings())
            else
              _action(c, '立即安装', () => ref.read(updateDownloadProvider.notifier).install()),
            _ghost(c, '浏览器下载', () => _openBrowser(state)),
            _ghost(c, '暂不安装', () => ref.read(updateDownloadProvider.notifier).dismiss()),
          ]),
        ];
      case UpdateDownloadFailed(:final reason):
        final other = otherChannel(state.info, state.channel);
        return <Widget>[
          Text(reason, style: TextStyle(fontSize: 12, height: 1.45, color: c.textSecondary)),
          const SizedBox(height: Spacing.three),
          _buttons(<Widget>[
            _action(c, '继续下载', () => ref.read(updateDownloadProvider.notifier).retry()),
            if (other != null)
              _ghost(c, '换到 ${other.name}', () => ref.read(updateDownloadProvider.notifier).retryWith(other)),
            _ghost(c, '浏览器下载', () => _openBrowser(state)),
            _ghost(c, '关闭', () => ref.read(updateDownloadProvider.notifier).dismiss()),
          ]),
        ];
    }
  }

  Widget _buttons(List<Widget> children) => Wrap(
    spacing: Spacing.two,
    runSpacing: Spacing.two,
    alignment: WrapAlignment.start,
    children: children,
  );

  Widget _action(FindrColors c, String label, VoidCallback onTap) => TextButton(
    onPressed: onTap,
    style: TextButton.styleFrom(
      backgroundColor: c.record,
      foregroundColor: c.recordText,
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.three, vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
    ),
    child: Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
  );

  Widget _ghost(FindrColors c, String label, VoidCallback onTap) => TextButton(
    onPressed: onTap,
    style: TextButton.styleFrom(
      foregroundColor: c.textSecondary,
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.two, vertical: 8),
    ),
    child: Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
  );

  /// 浏览器兜底：直接开当前渠道的下载地址（浏览器会把它当下载或打开发布页）。
  /// 拉不起来就**在卡片里说**（这里没有 toast 可用）。
  Future<void> _openBrowser(UpdateTaskState state) async {
    var ok = false;
    try {
      ok = await launchUrl(Uri.parse(state.channel.url), mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      setState(() => _note = '打不开浏览器，请手动访问：${state.channel.url}');
    }
  }

  String _fileSize(File file) {
    try {
      return _fmtBytes(file.lengthSync());
    } catch (_) {
      return '已下载';
    }
  }

  String _fmtBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
