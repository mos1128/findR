/// ZIP 成员校验用。
///
/// 纯计算、无平台依赖，只用 `Uint32List`。
///
/// ⚠️ **别换 `dart:io` / 第三方的 CRC 实现**：这是**备份格式的一部分**，
/// 算法与多项式按标准 CRC32 实现 —— 容器要能被通用解压工具打开。
library;

import 'dart:typed_data';

/// 标准 CRC-32（IEEE 802.3，反射多项式 `0xedb88320`）查表。
///
/// 表是模块级常量，只算一次。
final Uint32List crc32Table = _buildTable();

Uint32List _buildTable() {
  final t = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      // Dart 没有 `>>>`，但 c 始终在 [0, 2^32) 内，`>>` 与 `>>>` 等价。
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
    t[i] = c;
  }
  return t;
}

/// 返回值恒在 [0, 2^32)。
///
/// Dart 的 int 是 64 位有符号，`c ^ 0xffffffff` 本身就落在 [0, 2^32) 内，
/// **不需要也不该**再掩码（掩了反而没变化）。
int crc32(Uint8List data) {
  var c = 0xffffffff;
  for (var i = 0; i < data.length; i++) {
    c = crc32Table[(c ^ data[i]) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}
