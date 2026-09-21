import 'dart:convert';

import 'package:findr_core/findr_core.dart';
import 'package:test/test.dart';

/// 对应 TS `providers.test.ts` 的第一条用例。
///
/// 这一份是**逐字搬的纯算法**（理由见 `lib/util/base64.dart` 的文件头），
/// 所以测试也要逐条对齐 —— 尤其是**宽容解码**那条，它是我们刻意不换成
/// `base64Decode` 的唯一原因。
void main() {
  test('编解码往返（含非 3 字节倍数）', () {
    for (final len in [0, 1, 2, 3, 4, 61, 256]) {
      final bytes = List<int>.generate(len, (i) => (i * 37) & 0xff);
      expect(base64ToBytes(bytesToBase64(bytes)), bytes, reason: 'len=$len');
    }
  });

  test('解码宽容：换行与 = 填充被忽略', () {
    // 'AA\nBB==' → 0x00 0x00 0x41
    expect(base64ToBytes('AA\nBB=='), [0x00, 0x00, 0x41]);
    expect(base64ToBytes('QUJD'), [0x41, 0x42, 0x43]);
  });

  test('解码宽容：字母表外的字符一律跳过（dart:convert 会在这里抛）', () {
    expect(base64ToBytes('QU*JD'), [0x41, 0x42, 0x43]);
    expect(base64ToBytes('  QUJD  '), [0x41, 0x42, 0x43]);
    expect(base64ToBytes('QU\r\nJD'), [0x41, 0x42, 0x43]);
    // 对照：dart:convert 对同样输入是抛异常 —— 这条断言钉住「我们为什么不用它」
    expect(() => base64Decode('QU*JD'), throwsFormatException);
  });

  test('编码补齐到 4 的倍数，且与 dart:convert 结果一致', () {
    for (final len in [0, 1, 2, 3, 4, 5, 6, 7, 61, 256]) {
      final bytes = List<int>.generate(len, (i) => (i * 11 + 3) & 0xff);
      final ours = bytesToBase64(bytes);
      expect(ours.length % 4, 0, reason: 'len=$len');
      expect(ours, base64Encode(bytes), reason: 'len=$len');
    }
  });

  test('编解码往返：中文与 emoji 走字节层不丢', () {
    final original = '圆珠笔放主卧衣柜顶层 🎒';
    final bytes = utf8Encode(original);
    expect(bytesToBase64(bytes), base64Encode(bytes));
    expect(utf8Decode(base64ToBytes(bytesToBase64(bytes))), original);
  });
}
