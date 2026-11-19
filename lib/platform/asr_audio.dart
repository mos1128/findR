/// 把沙盒里的录音变成模型能吃的采样。
///
/// 两段拼起来做这件事：
///   1. **解码**走 Kotlin（`findr/audio` 通道）—— Dart 没有 AAC 解码器，
///      而库里存的就是 AAC（`.m4a`，44.1 kHz 单声道，见 `capture/recorder.dart`）；
///   2. **下混 + 重采样**在 [toSpeechSamples] 里算（`pcm.dart`，纯函数、有单测）。
library;

import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'pcm.dart';

const MethodChannel _channel = MethodChannel('findr/audio');

/// 录音文件 → 16 kHz 单声道浮点采样。[path] 是绝对路径。
///
/// 交给系统解码器，所以 `.m4a` / `.mp3` / `.wav` 都能吃 —— 也因此**老录音照样能转写**，
/// 不必为「换引擎之前录的那批」单开一条路。
Future<Float32List> speechSamplesFromFile(String path) async {
  final Map<String, Object?>? raw;
  try {
    raw = await _channel.invokeMapMethod<String, Object?>('decodePcm', {
      'path': path,
    });
  } on MissingPluginException {
    // 只有 Android 有这条通道；桌面端与测试里走到这儿说明调用方没拦住
    throw StateError('当前设备无法解码录音');
  } on PlatformException catch (e) {
    throw StateError(e.message ?? '录音解码失败');
  }
  final pcm = raw?['pcm'];
  final rate = raw?['sampleRate'];
  final channels = raw?['channels'];
  if (pcm is! Uint8List ||
      rate is! int ||
      channels is! int ||
      rate <= 0 ||
      channels <= 0) {
    throw StateError('录音解码失败：文件里没有可用的音频');
  }
  return toSpeechSamples(pcm, sampleRate: rate, channels: channels);
}
