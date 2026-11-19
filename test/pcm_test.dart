import 'dart:math' as math;
import 'dart:typed_data';

import 'package:findr_app/platform/pcm.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一段 PCM16 单声道正弦。
Uint8List _tone(
  double hz, {
  required int sampleRate,
  required int frames,
  double amplitude = 0.5,
}) {
  final bytes = ByteData(frames * 2);
  for (var i = 0; i < frames; i++) {
    final v = amplitude * math.sin(2 * math.pi * hz * i / sampleRate);
    bytes.setInt16(i * 2, (v * 32767).round(), Endian.little);
  }
  return bytes.buffer.asUint8List();
}

/// 取中段（跳过滤波器起始的过渡）的峰值。
double _peak(Float32List samples) {
  final from = samples.length ~/ 4;
  final to = samples.length * 3 ~/ 4;
  var peak = 0.0;
  for (var i = from; i < to; i++) {
    final v = samples[i].abs();
    if (v > peak) peak = v;
  }
  return peak;
}

void main() {
  group('toSpeechSamples', () {
    test('16 kHz 直接透传，一个采样都不动', () {
      final pcm = _tone(1000, sampleRate: 16000, frames: 1600);
      final out = toSpeechSamples(pcm, sampleRate: 16000, channels: 1);
      expect(out.length, 1600);
      expect(out[800], closeTo(0.5 * math.sin(2 * math.pi * 50), 1e-4));
    });

    test('44.1 kHz 降到 16 kHz，长度按比例缩', () {
      final pcm = _tone(1000, sampleRate: 44100, frames: 44100);
      final out = toSpeechSamples(pcm, sampleRate: 44100, channels: 1);
      expect(out.length, (44100 * 16000 / 44100).round());
    });

    test('语声频段（1 kHz）的幅度基本不动', () {
      final pcm = _tone(1000, sampleRate: 44100, frames: 44100);
      final out = toSpeechSamples(pcm, sampleRate: 44100, channels: 1);
      expect(_peak(out), closeTo(0.5, 0.05));
    });

    test('8 kHz 以上被压掉，不会折回到语音频段', () {
      final pcm = _tone(12000, sampleRate: 44100, frames: 44100);
      final out = toSpeechSamples(pcm, sampleRate: 44100, channels: 1);
      expect(_peak(out), lessThan(0.5 * 0.25));
    });

    test('多声道取平均（左右反相的整段抵消）', () {
      final bytes = ByteData(100 * 4);
      for (var i = 0; i < 100; i++) {
        bytes.setInt16(i * 4, 16384, Endian.little);
        bytes.setInt16(i * 4 + 2, -16384, Endian.little);
      }
      final out = toSpeechSamples(
        bytes.buffer.asUint8List(),
        sampleRate: 16000,
        channels: 2,
      );
      expect(out.length, 100);
      expect(out.every((v) => v == 0), isTrue);
    });

    test('半个采样帧的尾巴不会越界', () {
      final out = toSpeechSamples(
        Uint8List.fromList(<int>[1, 2, 3]),
        sampleRate: 16000,
        channels: 2,
      );
      expect(out, isEmpty);
    });

    test('采样率或声道数非正就报错', () {
      expect(
        () => toSpeechSamples(Uint8List(0), sampleRate: 0, channels: 1),
        throwsArgumentError,
      );
      expect(
        () => toSpeechSamples(Uint8List(0), sampleRate: 16000, channels: 0),
        throwsArgumentError,
      );
    });
  });
}
