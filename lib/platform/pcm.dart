/// 采样格式转换 —— **纯计算，不碰平台通道**。
///
/// 拆出来的唯一理由：这样 `tool/` 下的脚本能在桌面端用 `dart run` 直接验证它
/// （桌面没有 `dart:ui`，只要碰到 `package:flutter` 就编不过）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 模型的固定入口采样率 —— SenseVoice 只认 16 kHz。
const int speechSampleRate = 16000;

/// PCM16 小端（按声道交织）→ 16 kHz 单声道浮点。
///
/// 降采样前必须先削掉 8 kHz 以上的部分：不削的话那些频率会**折回**到语音频段，
/// 变成听得见的噪声喂给模型。两个二阶巴特沃斯级联（Q 是它的两个极点），四阶够用。
Float32List toSpeechSamples(
  Uint8List pcm16, {
  required int sampleRate,
  required int channels,
}) {
  if (sampleRate <= 0 || channels <= 0) {
    throw ArgumentError('采样率与声道数必须为正：$sampleRate Hz / $channels ch');
  }
  final frames = pcm16.length ~/ (2 * channels);
  if (frames == 0) return Float32List(0);

  final data = ByteData.sublistView(pcm16);
  final mono = Float32List(frames);
  for (var i = 0; i < frames; i++) {
    var sum = 0.0;
    for (var c = 0; c < channels; c++) {
      sum += data.getInt16((i * channels + c) * 2, Endian.little) / 32768.0;
    }
    mono[i] = sum / channels;
  }
  if (sampleRate == speechSampleRate) return mono;

  final rate = sampleRate.toDouble();
  final cutoff = math.min(7000.0, sampleRate * 0.45);
  var filtered = _lowpass(mono, rate, cutoff, 0.54119610);
  filtered = _lowpass(filtered, rate, cutoff, 1.30656296);

  final outFrames = (frames * speechSampleRate / sampleRate).round();
  final out = Float32List(outFrames);
  final step = sampleRate / speechSampleRate;
  for (var i = 0; i < outFrames; i++) {
    final pos = i * step;
    final i0 = pos.floor();
    final a = filtered[i0 < frames ? i0 : frames - 1];
    final b = filtered[i0 + 1 < frames ? i0 + 1 : frames - 1];
    out[i] = a + (b - a) * (pos - i0);
  }
  return out;
}

/// 二阶低通（RBJ 双二次，direct form I）。
Float32List _lowpass(Float32List input, double rate, double cutoff, double q) {
  final w0 = 2 * math.pi * cutoff / rate;
  final cosw = math.cos(w0);
  final alpha = math.sin(w0) / (2 * q);
  final a0 = 1 + alpha;
  final b0 = (1 - cosw) / 2 / a0;
  final b1 = (1 - cosw) / a0;
  final a1 = -2 * cosw / a0;
  final a2 = (1 - alpha) / a0;

  final out = Float32List(input.length);
  var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0;
  for (var i = 0; i < input.length; i++) {
    final x = input[i];
    final y = b0 * x + b1 * x1 + b0 * x2 - a1 * y1 - a2 * y2;
    out[i] = y;
    x2 = x1;
    x1 = x;
    y2 = y1;
    y1 = y;
  }
  return out;
}
