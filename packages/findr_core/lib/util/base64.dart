/// 纯 Dart 的 base64 编解码。
///
/// ⚠️ **为什么不直接用 `dart:convert` 的 `base64Encode` / `base64Decode`**：
/// **行为上有一处真的不一样，而且是我们依赖的**：
/// 解码器**遇到非法字符静默跳过**（换行、`=` 填充、任何字母表外的字符都直接略过，
/// 返回已解出的部分）；`base64Decode` 遇到非法字符直接抛 `FormatException`。
/// 备份包的 manifest 里全是中文、且历史上出现过带换行的 base64 值，
/// 两种语义在「坏输入」上分道扬镳 ⇒ **保守起见自己实现，行为可证相同**。
///
/// 另一处刻意保留的是**位运算的掩码**：Dart 的 int 是 64 位、移位不会回绕，
/// 而我们要取的只是低位（`bits` 永远不超过 13，只读低 14 位）。
/// `& 0xffffffff` 让这个意图显式化，免得将来有人误以为高位也归零。
library;

import 'dart:typed_data';

const String _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/// 逆向表：字符码 → 6bit 值，非法字符标 -1。
final List<int> _lookup = () {
  final table = List<int>.filled(128, -1);
  for (var i = 0; i < _alphabet.length; i++) {
    table[_alphabet.codeUnitAt(i)] = i;
  }
  return table;
}();

/// 解码。**对非法字符宽容**：跳过换行、`=` 填充与一切字母表外的字符。
///
/// 注意输出长度按 `floor(n * 3 / 4)` 预分配、最后按实际写入长度截断，
/// 所以「跳过的字符」不会在尾部留下空字节。
/// 返回的是**视图**，不是拷贝。
Uint8List base64ToBytes(String input) {
  final n = input.length;
  final out = Uint8List((n * 3) ~/ 4);
  var outLen = 0;
  var buffer = 0;
  var bits = 0;
  for (var i = 0; i < n; i++) {
    final code = input.codeUnitAt(i);
    final value = code < 128 ? _lookup[code] : -1;
    if (value < 0) continue; // 跳过换行、`=` 填充等
    buffer = (buffer << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[outLen++] = (buffer >> bits) & 0xff;
    }
  }
  return Uint8List.sublistView(out, 0, outLen);
}

/// 编码，输出带 `=` 补齐到 4 的倍数（标准 base64）。
String bytesToBase64(List<int> bytes) {
  final out = StringBuffer();
  var buffer = 0;
  var bits = 0;
  for (var i = 0; i < bytes.length; i++) {
    buffer = ((buffer << 8) | bytes[i]) & 0xffffffff;
    bits += 8;
    while (bits >= 6) {
      bits -= 6;
      out.write(_alphabet[(buffer >> bits) & 0x3f]);
    }
  }
  if (bits > 0) out.write(_alphabet[(buffer << (6 - bits)) & 0x3f]);
  final pad = (4 - out.length % 4) % 4;
  return out.toString() + '=' * pad;
}
