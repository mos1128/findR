/// 「分享到 Findr」。
///
/// 微信、浏览器、相册里的东西分享过来时，Android 走的是 `ACTION_SEND`（清单里那个
/// intent-filter）。这里把它变成首页录入条里预填的内容 —— 用户补一句话就能存。
///
/// **为什么不是「分享即存」**：分享过来的一段 URL 或一张图，往往缺「这是什么」。
/// 直接落盘会得到一张待整理的卡，用户还要回头去补；预填在录入条里，他顺手补完再存，
/// 一步都不多花。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const MethodChannel _channel = MethodChannel('findr/share');

/// 一次分享进来的东西。`text` 与 `paths` 至少有一个非空。
@immutable
class InboundShare {
  const InboundShare({this.text, this.paths = const <String>[]});

  final String? text;

  /// 已经拷进本应用 cache 的本机路径（Kotlin 侧拷的，见 `MainActivity.copyToCache`）。
  final List<String> paths;
}

class InboundShareNotifier extends ValueNotifier<InboundShare?> {
  InboundShareNotifier() : super(null);

  /// 挂通道，并回一句 `ready`。
  ///
  /// 冷启动时用户的分享 intent 比 Dart 这边早到：Kotlin 会先扣住，等这句 `ready`
  /// 再递过来。没有这一步，从桌面图标冷启动的分享会被静默丢掉。
  Future<void> attach() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'share') return;
      final args = call.arguments as Map? ?? const <String, Object?>{};
      final paths =
          (args['paths'] as List?)?.whereType<String>().toList() ??
          const <String>[];
      final text = (args['text'] as String?)?.trim();
      if (paths.isEmpty && (text == null || text.isEmpty)) return;
      value = InboundShare(text: text, paths: paths);
    });
    try {
      await _channel.invokeMethod<void>('ready');
    } on MissingPluginException {
      // 桌面端 / 测试里没有这条通道：分享根本不是这些平台的能力
    }
  }
}

/// 首页录入条监听它，取走即置空。
final inboundShareProvider = Provider<InboundShareNotifier>((ref) {
  final notifier = InboundShareNotifier();
  unawaited(notifier.attach());
  ref.onDispose(notifier.dispose);
  return notifier;
});
