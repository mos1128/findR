/// ZIP 成员校验用 —— 逐字对应 `packages/core/src/backup/crc32.ts`（16 行）。
///
/// 纯计算、无平台依赖。TS 侧在 Hermes 上同样可用，Dart 侧更是只用 `Uint32List`。
///
/// ⚠️ **别换 `dart:io` / 第三方的 CRC 实现**：这是**备份格式的一部分**，
/// 算出来的值要与 RN 版写出的包逐位一致（RN 版导出的包要能被 Flutter 版导入，反之亦然）。
library;

import 'dart:typed_data';

/// 标准 CRC-32（IEEE 802.3，反射多项式 `0xedb88320`）查表。
///
/// 表是模块级常量，只算一次 —— 与 TS 的顶层 IIFE 同一个意图。
final Uint32List crc32Table = _buildTable();

Uint32List _buildTable() {
  final t = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      // TS 是 `(c & 1) !== 0 ? 0xedb88320 ^ (c >>> 1) : c >>> 1`。
      // Dart 没有 `>>>`，但 c 始终在 [0, 2^32) 内，`>>` 与 `>>>` 等价。
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
    t[i] = c;
  }
  return t;
}

/// 与 TS 的 `crc32()` 同值。返回值恒在 [0, 2^32)。
///
/// TS 末尾的 `>>> 0` 是为了把 JS 的有符号 32 位结果掰回无符号；Dart 的 int 是 64 位有符号，
/// `c ^ 0xffffffff` 本身就落在 [0, 2^32) 内，**不需要也不该**再掩码（掩了反而没变化）。
int crc32(Uint8List data) {
  var c = 0xffffffff;
  for (var i = 0; i < data.length; i++) {
    c = crc32Table[(c ^ data[i]) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}
