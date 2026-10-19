/// 「检查更新」查到新版本之后的两个弹窗：选源（Gitee / GitHub / 浏览器 / 稍后）与
/// 「浏览器下载」二级入口。
///
/// **这里不做下载**：点完源就把活交给 `state/update_download.dart` 的控制器 ——
/// 下载在后台跑，进度看右下角的小图标（`ui/update_pill.dart`）。所以这个文件很小：
/// 它只负责「问清楚用户想要什么」和「兜底开浏览器」。
///
/// 正文里那句「安装时直接覆盖安装（别卸载），本地数据不会丢」是硬口径，**别删**
/// —— 它成立的前提是「所有版本都签同一把证书」（debug 包也一样，见 build.gradle.kts）。
library;

import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../platform/update.dart';
import '../../state/update_download.dart';
import '../../theme/tokens.dart';

/// 选源弹窗里「浏览器下载」这个选项（它不是某个渠道，单独当一种结果传出来）。
final class _BrowserChoice {
  const _BrowserChoice();
}

/// 发现新版本时弹「怎么更新」。用户点了某个源就交给控制器开始下载。
Future<void> showUpdateFlow(
  BuildContext context,
  WidgetRef ref, {
  required UpdateInfo info,
  required String currentLabel,
}) async {
  final channels = downloadChannels(info);
  final pick = await showDialog<Object?>(
    context: context,
    builder: (ctx) => _sourceDialog(ctx, info: info, currentLabel: currentLabel, channels: channels),
  );
  if (!context.mounted) return;
  switch (pick) {
    case UpdateChannel channel:
      await _startDownload(context, ref, info, channel);
    case _BrowserChoice():
      await _showBrowserDialog(context, channels);
  }
}

AlertDialog _sourceDialog(
  BuildContext ctx, {
  required UpdateInfo info,
  required String currentLabel,
  required List<UpdateChannel> channels,
}) {
  final c = FindrColors.of(ctx);
  return AlertDialog(
    backgroundColor: c.surface,
    title: Text(
      '发现新版本 v${info.version}',
      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.text),
    ),
    content: SingleChildScrollView(
      child: Text(
        '当前版本 $currentLabel\n\n'
        '${info.notes ?? '暂无更新说明。'}\n\n'
        '安装时直接覆盖安装（别卸载），本地数据不会丢。\n'
        '下载在 App 内进行，可以缩成右下角的小图标，边用边下。',
        style: TextStyle(fontSize: 13, height: 1.5, color: c.textSecondary),
      ),
    ),
    actions: <Widget>[
      for (final channel in channels)
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(channel),
          child: Text(
            '${channel.name} 更新',
            style: TextStyle(color: c.record, fontWeight: FontWeight.w600),
          ),
        ),
      TextButton(
        onPressed: () => Navigator.of(ctx).pop(const _BrowserChoice()),
        child: Text('浏览器下载', style: TextStyle(color: c.record)),
      ),
      TextButton(
        onPressed: () => Navigator.of(ctx).pop(),
        child: Text('稍后再说', style: TextStyle(color: c.textSecondary)),
      ),
    ],
  );
}

/// 「浏览器下载」的二级弹窗：两个渠道各开一个下载页。
/// 它既是「不想在 App 里下」的入口，也是自动下载失败后的兜底（小图标卡片里也会走到这）。
Future<void> _showBrowserDialog(BuildContext context, List<UpdateChannel> channels) async {
  final pick = await showDialog<UpdateChannel>(
    context: context,
    builder: (ctx) {
      final c = FindrColors.of(ctx);
      return AlertDialog(
        backgroundColor: c.surface,
        title: Text('浏览器下载', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.text)),
        content: Text(
          '在系统浏览器里打开下载页。\n自动下载不成功时，这里总能走通。',
          style: TextStyle(fontSize: 13, height: 1.5, color: c.textSecondary),
        ),
        actions: <Widget>[
          for (final channel in channels)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(channel),
              child: Text(
                '${channel.name} 下载页',
                style: TextStyle(color: c.record, fontWeight: FontWeight.w600),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消', style: TextStyle(color: c.textSecondary)),
          ),
        ],
      );
    },
  );
  if (pick == null || !context.mounted) return;
  await _openUrl(context, pick.url);
}

/// 把源交给控制器。三种「不用重下」的情形在这里挡掉，别打断正在跑的任务。
Future<void> _startDownload(
  BuildContext context,
  WidgetRef ref,
  UpdateInfo info,
  UpdateChannel channel,
) async {
  final current = ref.read(updateDownloadProvider);
  if (current is UpdateDownloading) {
    _toast(context, '更新正在下载中，进度见右下角小图标');
    return;
  }
  if (current is UpdateReady && current.info.tag == info.tag) {
    _toast(context, '安装包已下载好，正在打开安装界面');
    await ref.read(updateDownloadProvider.notifier).install();
    return;
  }
  ref.read(updateDownloadProvider.notifier).start(info: info, channel: channel);
  _toast(context, '已从 ${channel.name} 开始下载，进度见右下角小图标');
}

/// 打开外部链接。**失败要说话** —— 静默失败会被当成「点了没反应」。
Future<void> _openUrl(BuildContext context, String url) async {
  var ok = false;
  try {
    ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    ok = false;
  }
  if (!ok && context.mounted) _toast(context, '打不开浏览器，请手动访问：$url');
}

void _toast(BuildContext context, String message) {
  final c = FindrColors.of(context);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message, style: TextStyle(fontSize: 13, color: c.text)),
        backgroundColor: c.surface,
        behavior: SnackBarBehavior.floating,
      ),
    );
}
