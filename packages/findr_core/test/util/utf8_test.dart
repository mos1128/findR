import 'dart:convert';

import 'package:findr_core/findr_core.dart';
import 'package:test/test.dart';

/// `util/utf8.dart` 是逐字搬的纯算法（理由见该文件头）。
///
/// ⚠️ **多数断言拿 `dart:convert` 当对照**（值必须一样），
/// **唯一刻意不同的是「截断输入」那条**：TS 那边越界读数组得到 `undefined`、
/// 参与位运算等于 0，于是它会**静默按 0 补齐**继续解；Dart 若不特别处理就抛 `RangeError`。
/// 我们选择保住 TS 的宽容语义（备份包解析路上「崩掉」比「解出错字」更难收拾）。
void main() {
  test('与 dart:convert 逐字对齐：中英文、标点、emoji', () {
    for (final text in [
      '',
      'a',
      '圆珠笔放主卧衣柜顶层',
      '护照 · 港澳通行证',
      '🎒🧳📷',
      'a🎒b',
      '“引号”与\u0000控制符',
      '\u{10FFFF}', // 最大码点，4 字节
    ]) {
      expect(utf8Encode(text), utf8.encode(text), reason: text);
      expect(utf8Decode(utf8.encode(text)), text, reason: text);
    }
  });

  test('往返：编码后的字节再解回来是原串', () {
    const text = '主卧衣柜顶层有手电筒，电池在抽屉里（2 号）🔋';
    expect(utf8Decode(utf8Encode(text)), text);
  });

  test('代理对按 4 字节编码，不是拆成两个 3 字节', () {
    final bytes = utf8Encode('🎒');
    expect(bytes, [0xf0, 0x9f, 0x8e, 0x92]);
    expect(utf8Decode(bytes), '🎒');
  });

  test('截断的字节序列按 0 补齐，不抛异常（对齐 JS 的 undefined→0）', () {
    // '圆' 是 3 字节，只给前两个
    final full = utf8Encode('圆');
    expect(full.length, 3);
    final truncated = full.sublist(0, 2);
    expect(() => utf8Decode(truncated), returnsNormally);
    // 对照：dart:convert 对同样输入是抛异常
    expect(() => utf8.decode(truncated), throwsFormatException);
  });

  test('孤立的低代理码元不吞掉（不做非法序列修复）', () {
    // 单个低代理码元 0xDC00：TS 那边会照原样编成 3 字节
    final bytes = utf8Encode('\udc00');
    expect(bytes.length, 3);
    expect(utf8Decode(bytes), '\udc00');
  });

  test('base64 → utf8 走完整链路（备份 manifest 的真实路径）', () {
    const text = '{"name":"圆珠笔","path":["主卧","衣柜"]}';
    final encoded = bytesToBase64(utf8Encode(text));
    expect(utf8Decode(base64ToBytes(encoded)), text);
  });
}
