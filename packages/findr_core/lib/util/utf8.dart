/// 纯 Dart 的 UTF-8 编解码 —— 逐字对应 `packages/core/src/util/utf8.ts`（64 行）。
///
/// ⚠️ **为什么不直接用 `dart:convert` 的 `utf8.encode` / `utf8.decode`**：
/// 与 [base64ToBytes] 同一个判断 —— TS 那份不用的理由是 Hermes，Dart 这边没这个理由，
/// 但这段代码的**真实职责是「备份 manifest 的字节布局必须可证一致」**（TS 原注释：
/// 「备份 manifest 里全是中文，这条路必须稳」）。逐字搬 = 行为可证相同，代价只有 60 行。
///
/// **一处必须在 Dart 侧补上的等价物**：JS 读越界的数组元素得到 `undefined`，
/// 而 `undefined & 0x3f` 在 JS 里是 `0` —— 也就是说 TS 那份遇到**截断的字节序列**时
/// 会静默按 0 补齐、继续解出乱码，而不是报错。Dart 直接下标会抛 `RangeError`，
/// 所以这里用 [_byteAt] 把「越界当 0」显式表达出来，保持同样的宽容语义。
library;

import 'dart:typed_data';

/// JS 的 `bytes[i]`：越界得到 `undefined`，参与位运算时等于 0。
int _byteAt(Uint8List bytes, int index) => index < bytes.length ? bytes[index] : 0;

/// 编码成 UTF-8 字节。代理对（emoji 等 4 字节字符）按 JS 的 `charCodeAt` 语义合并两个码元。
Uint8List utf8Encode(String input) {
  final out = <int>[];
  for (var i = 0; i < input.length; i++) {
    var cp = input.codeUnitAt(i);
    if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < input.length) {
      final low = input.codeUnitAt(i + 1);
      if (low >= 0xdc00 && low <= 0xdfff) {
        cp = ((cp - 0xd800) << 10) + (low - 0xdc00) + 0x10000;
        i++;
      }
    }
    if (cp < 0x80) {
      out.add(cp);
    } else if (cp < 0x800) {
      out.add(0xc0 | (cp >> 6));
      out.add(0x80 | (cp & 0x3f));
    } else if (cp < 0x10000) {
      out.add(0xe0 | (cp >> 12));
      out.add(0x80 | ((cp >> 6) & 0x3f));
      out.add(0x80 | (cp & 0x3f));
    } else {
      out.add(0xf0 | (cp >> 18));
      out.add(0x80 | ((cp >> 12) & 0x3f));
      out.add(0x80 | ((cp >> 6) & 0x3f));
      out.add(0x80 | (cp & 0x3f));
    }
  }
  return Uint8List.fromList(out);
}

/// 解码 UTF-8 字节。**截断的序列按 0 补齐**（见文件头注释），不抛异常。
String utf8Decode(Uint8List bytes) {
  final out = StringBuffer();
  var i = 0;
  while (i < bytes.length) {
    final b0 = bytes[i++];
    int cp;
    if (b0 < 0x80) {
      cp = b0;
    } else if (b0 >= 0xc0 && b0 < 0xe0) {
      cp = ((b0 & 0x1f) << 6) | (_byteAt(bytes, i++) & 0x3f);
    } else if (b0 >= 0xe0 && b0 < 0xf0) {
      cp = ((b0 & 0x0f) << 12) | ((_byteAt(bytes, i++) & 0x3f) << 6) | (_byteAt(bytes, i++) & 0x3f);
    } else {
      cp =
          ((b0 & 0x07) << 18) |
          ((_byteAt(bytes, i++) & 0x3f) << 12) |
          ((_byteAt(bytes, i++) & 0x3f) << 6) |
          (_byteAt(bytes, i++) & 0x3f);
    }
    if (cp > 0xffff) {
      cp -= 0x10000;
      out.writeCharCode(0xd800 + (cp >> 10));
      out.writeCharCode(0xdc00 + (cp & 0x3ff));
    } else {
      out.writeCharCode(cp);
    }
  }
  return out.toString();
}
