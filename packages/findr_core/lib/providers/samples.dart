/// 能力探测用的微型样本。
///
/// 样本**运行时生成**而非往仓库里塞二进制：
/// PNG 走「**存储型 deflate 块**」（= 声明「这段没压缩」，于是免于实现 deflate），
/// WAV 是无损 PCM。两者都是确定性的 ⇒ 同样的输入永远得到同样的字节，
/// 测试才能拿结构本身当断言（见 `test/providers/providers_test.dart`）。
///
/// 字节序：PNG 用**大端**（`ByteData.setUint32` 默认即 `Endian.big`）；
/// WAV 用**小端**，所以那里显式写 `Endian.little`。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../util/base64.dart';

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c >>> 0;
  }
  return table;
}();

int _crc32(Uint8List bytes) {
  var c = 0xffffffff;
  for (var i = 0; i < bytes.length; i++) {
    c = _crcTable[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) >>> 0;
}

int _adler32(Uint8List bytes) {
  var a = 1;
  var b = 0;
  for (var i = 0; i < bytes.length; i++) {
    a = (a + bytes[i]) % 65521;
    b = (b + a) % 65521;
  }
  return ((b << 16) | a) >>> 0;
}

Uint8List _concat(List<Uint8List> parts) {
  var total = 0;
  for (final p in parts) {
    total += p.length;
  }
  final out = Uint8List(total);
  var offset = 0;
  for (final p in parts) {
    out.setRange(offset, offset + p.length, p);
    offset += p.length;
  }
  return out;
}

/// 一个 PNG 块：`长度(4) + 类型(4) + 数据 + CRC(4)`，CRC 覆盖「类型 + 数据」。
Uint8List _pngChunk(String type, Uint8List data) {
  final out = Uint8List(12 + data.length);
  final view = out.buffer.asByteData();
  view.setUint32(0, data.length);
  for (var i = 0; i < 4; i++) {
    out[4 + i] = type.codeUnitAt(i);
  }
  out.setRange(8, 8 + data.length, data);
  view.setUint32(8 + data.length, _crc32(Uint8List.sublistView(out, 4, 8 + data.length)));
  return out;
}

/// zlib 容器 + 存储型 deflate 块（不压缩，省掉实现 deflate 的必要）。
Uint8List _zlibStored(Uint8List raw) {
  final parts = <Uint8List>[Uint8List.fromList([0x78, 0x01])];
  var offset = 0;
  do {
    final len = raw.length - offset < 65535 ? raw.length - offset : 65535;
    final last = offset + len >= raw.length ? 1 : 0;
    final header = Uint8List(5);
    header[0] = last;
    header[1] = len & 0xff;
    header[2] = (len >>> 8) & 0xff;
    header[3] = ~len & 0xff;
    header[4] = (~len >>> 8) & 0xff;
    parts.add(header);
    parts.add(Uint8List.sublistView(raw, offset, offset + len));
    offset += len;
  } while (offset < raw.length);
  final adler = Uint8List(4);
  adler.buffer.asByteData().setUint32(0, _adler32(raw));
  parts.add(adler);
  return _concat(parts);
}

/// 64×64 灰度 PNG（棋盘图案，避免全平图被模型当成占位符），约 4KB。
///
/// 颜色类型 0 = 灰度、位深 8 ⇒ 每像素 1 字节；每行前置一个 filter byte（0 = None）。
Uint8List makeTestPng([int size = 64]) {
  final ihdr = Uint8List(13);
  final view = ihdr.buffer.asByteData();
  view.setUint32(0, size);
  view.setUint32(4, size);
  ihdr[8] = 8; // 位深
  ihdr[9] = 0; // 颜色类型：灰度

  final raw = Uint8List(size * (size + 1));
  for (var y = 0; y < size; y++) {
    final rowStart = y * (size + 1);
    raw[rowStart] = 0; // 每行前置 filter byte（None）
    for (var x = 0; x < size; x++) {
      raw[rowStart + 1 + x] = ((x >> 3) + (y >> 3)) % 2 == 0 ? 40 : 200;
    }
  }

  return _concat([
    Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    _pngChunk('IHDR', ihdr),
    _pngChunk('IDAT', _zlibStored(raw)),
    _pngChunk('IEND', Uint8List(0)),
  ]);
}

/// 1 秒 8kHz 单声道 8bit PCM WAV，带 440Hz 低幅正弦。
/// 只有设置页的 ASR 槽探测会把它发出去（试转一次，能返回就算连通）。
Uint8List makeTestWav([int seconds = 1, int sampleRate = 8000]) {
  final samples = (seconds * sampleRate).floor();
  final out = Uint8List(44 + samples);
  final view = out.buffer.asByteData();
  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      out[offset + i] = s.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  view.setUint32(4, 36 + samples, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  view.setUint32(16, 16, Endian.little); // fmt 块长度
  view.setUint16(20, 1, Endian.little); // PCM
  view.setUint16(22, 1, Endian.little); // 单声道
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, sampleRate, Endian.little); // 字节率 = 采样率 × 声道 × 位深/8
  view.setUint16(32, 1, Endian.little); // 块对齐
  view.setUint16(34, 8, Endian.little); // 位深
  ascii(36, 'data');
  view.setUint32(40, samples, Endian.little);

  for (var i = 0; i < samples; i++) {
    out[44 + i] = 128 + (20 * math.sin(2 * math.pi * 440 * i / sampleRate)).round();
  }
  return out;
}

String testPngBase64([int size = 64]) => bytesToBase64(makeTestPng(size));

String testWavBase64([int seconds = 1]) => bytesToBase64(makeTestWav(seconds));
