/// 「检查更新」查到新版本之后的那个弹窗：分成「一键更新」与「手动更新」两块。
///
/// **这里不做下载**：点完源就把活交给 `state/update_download.dart` 的控制器 ——
/// 下载在后台跑，进度看右下角的小图标（`ui/update_pill.dart`）。所以这个文件很小：
/// 它只负责「问清楚用户想要什么」和「兜底开浏览器」。
///
/// 三条界面上的硬约束（真机反馈改出来的，别再退回去）：
/// 1. **按钮横排** —— 竖着排四个按钮会把弹窗撑得又长又没主次；
/// 2. **不再有二级弹窗** —— 「浏览器下载」以前还要再弹一次问走哪个渠道，纯属多余：
///    它本来就是个兜底，直接开默认渠道（Gitee）的下载页；
/// 3. **正文只显示 `---` 之前的更新说明**（`releaseNotesForApp`）—— 之后的安装须知
///    是给发布页读者看的，塞进弹窗既占地方又要跟着版本维护。
///
/// 正文里那句「覆盖安装即可，数据不会丢」是硬口径，**别删** ——
/// 它成立的前提是「所有版本都签同一把证书」（debug 包也一样，见 build.gradle.kts）。
library;

import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../platform/update.dart';
import '../../state/update_download.dart';
import '../../theme/tokens.dart';
import '../../ui/kit.dart';

/// 弹窗里「开浏览器」这个选择（它不是某个渠道，单独当一种结果传出来）。
final class _BrowserChoice {
  const _BrowserChoice(this.url);

  final String url;
}

/// 发现新版本时弹「怎么更新」。用户点了某个源就交给控制器开始下载。
Future<void> showUpdateFlow(
  BuildContext context,
  WidgetRef ref, {
  required UpdateInfo info,
  required String currentLabel,
}) async {
  final channels = downloadChannels(info);
  if (channels.isEmpty) return;
  final pick = await showDialog<Object?>(
    context: context,
    builder: (ctx) => _sourceDialog(ctx, info: info, currentLabel: currentLabel, channels: channels),
  );
  if (!context.mounted) return;
  switch (pick) {
    case UpdateChannel channel:
      await _startDownload(context, ref, info, channel);
    case _BrowserChoice(:final url):
      await _openUrl(context, url);
  }
}

AlertDialog _sourceDialog(
  BuildContext ctx, {
  required UpdateInfo info,
  required String currentLabel,
  required List<UpdateChannel> channels,
}) {
  final c = FindrColors.of(ctx);
  final primary = channels.first;
  final notes = releaseNotesForApp(info.notes) ?? '暂无更新说明。';
  return AlertDialog(
    backgroundColor: c.surface,
    titlePadding: const EdgeInsets.fromLTRB(Spacing.four, Spacing.four, Spacing.four, 0),
    contentPadding: const EdgeInsets.fromLTRB(Spacing.four, Spacing.three, Spacing.four, Spacing.three),
    actionsPadding: const EdgeInsets.fromLTRB(Spacing.four, 0, Spacing.four, Spacing.two),
    title: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '发现新版本 v${info.version}',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.text),
        ),
        const SizedBox(height: 2),
        Text('当前版本 $currentLabel', style: TextStyle(fontSize: 12, color: c.textMuted)),
      ],
    ),
    content: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(notes, style: TextStyle(fontSize: 13, height: 1.55, color: c.textSecondary)),
          const SizedBox(height: Spacing.three),
          Text(
            '覆盖安装即可，数据不丢；下载时可缩成小图标，边用边下。',
            style: TextStyle(fontSize: 11.5, height: 1.5, color: c.textMuted),
          ),
          const SizedBox(height: Spacing.five),
          // 选源交给用户：两个源并列、一样大、**同一个样式** ——
          // 不设"默认源"的视觉暗示（真机上反馈过：把 GitHub 塞进"手动"里读着别扭）。
          Row(
            children: <Widget>[
              for (var i = 0; i < channels.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: Spacing.two),
                Expanded(
                  child: FindrButton(
                    title: '${channels[i].name} 下载',
                    variant: FindrButtonVariant.secondary,
                    onPressed: () => Navigator.of(ctx).pop(channels[i]),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: Spacing.two),
          FindrButton(
            title: '浏览器打开下载页',
            variant: FindrButtonVariant.ghost,
            onPressed: () => Navigator.of(ctx).pop(_BrowserChoice(primary.url)),
          ),
        ],
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(ctx).pop(),
        child: Text('稍后再说', style: TextStyle(color: c.textSecondary)),
      ),
    ],
  );
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
