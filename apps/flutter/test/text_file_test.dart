/// 纯文本文件读入的验收网 —— `capture/text_file.dart`。
///
/// 这一块值得单测，因为**它的失败方式全都是「静默」的**：
/// 扩展名放宽一点、上限写成截断、BOM 没去掉，界面上都不会报错，
/// 只是内容悄悄不对了。需求 5.1 对这三条都有明文口径。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:findr_app/capture/text_file.dart';
import 'package:flutter_test/flutter_test.dart';

Future<List<int>> _bytes(String s) async => utf8.encode(s);
Future<List<int>> _raw(List<int> b) async => b;

void main() {
  group('扩展名白名单（需求 5.1 只支持纯文本类）', () {
    for (final ext in plainTextExtensions) {
      test('.$ext 放行', () async {
        final res = await decodePlainText(
          name: 'note.$ext',
          readBytes: () => _bytes('放在主卧抽屉'),
        );
        expect(res, isA<TextFileOk>());
        expect((res as TextFileOk).text, '放在主卧抽屉');
      });
    }

    test('.MD 大写也放行（扩展名统一转小写再比）', () async {
      final res = await decodePlainText(name: 'NOTE.MD', readBytes: () => _bytes('x'));
      expect(res, isA<TextFileOk>());
    });

    test('.pdf 拒绝，并且说的是「请截图或复制文字」而不是含糊一句失败', () async {
      final res = await decodePlainText(name: '合同.pdf', readBytes: () => _bytes('%PDF'));
      expect(res, isA<TextFileRejected>());
      final msg = (res as TextFileRejected).message;
      expect(msg, contains('只支持纯文本文件'));
      expect(msg, contains('截图'));
    });

    test('.docx 拒绝', () async {
      final res = await decodePlainText(name: '简历.docx', readBytes: () => _bytes('x'));
      expect(res, isA<TextFileRejected>());
    });

    test('没有扩展名也拒绝', () async {
      final res = await decodePlainText(name: 'README', readBytes: () => _bytes('x'));
      expect(res, isA<TextFileRejected>());
    });
  });

  group('8000 字上限：超限必须拒绝，绝不静默截断', () {
    test('正好 8000 字放行', () async {
      final text = '字' * maxPlainTextChars;
      final res = await decodePlainText(name: 'a.txt', readBytes: () => _bytes(text));
      expect(res, isA<TextFileOk>());
      expect((res as TextFileOk).text.length, maxPlainTextChars);
    });

    test('8001 字拒绝，且告知实际字数（不返回被截断的 8000 字）', () async {
      final text = '字' * (maxPlainTextChars + 1);
      final res = await decodePlainText(name: 'a.txt', readBytes: () => _bytes(text));
      expect(res, isA<TextFileRejected>());
      final msg = (res as TextFileRejected).message;
      expect(msg, contains('${maxPlainTextChars + 1} 字'));
      expect(msg, contains('$maxPlainTextChars'));
    });
  });

  group('文本规范化', () {
    test('UTF-8 BOM 被去掉（否则会变成一个看不见的字符跟着标题走）', () async {
      final res = await decodePlainText(
        name: 'a.txt',
        readBytes: () => _raw(<int>[0xEF, 0xBB, 0xBF, ...utf8.encode('护照')]),
      );
      expect((res as TextFileOk).text, '护照');
    });

    test('首尾空白被 trim（空文件判定也靠它）', () async {
      final res = await decodePlainText(name: 'a.txt', readBytes: () => _bytes('\n\n  内容  \n\n'));
      expect((res as TextFileOk).text, '内容');
    });

    test('只有空白的文件算空文件', () async {
      final res = await decodePlainText(name: 'a.txt', readBytes: () => _bytes('   \n\t '));
      expect(res, isA<TextFileRejected>());
      expect((res as TextFileRejected).message, contains('空的'));
    });

    test('非 UTF-8（GBK 存的记事本）拒绝并说清是编码问题', () async {
      // 「护照」的 GBK 编码
      final res = await decodePlainText(
        name: 'a.txt',
        readBytes: () => _raw(Uint8List.fromList(<int>[0xBB, 0xA4, 0xD5, 0xD5])),
      );
      expect(res, isA<TextFileRejected>());
      expect((res as TextFileRejected).message, contains('UTF-8'));
    });

    test('读文件本身失败时也走「拒绝」而不是往上抛', () async {
      final res = await decodePlainText(
        name: 'a.txt',
        readBytes: () async => throw const FileSystemException('没权限'),
      );
      expect(res, isA<TextFileRejected>());
    });

    test('成功时带回文件名（界面要显示「已从「xx」读入 N 字」）', () async {
      final res = await decodePlainText(name: '购物清单.csv', readBytes: () => _bytes('a,b'));
      expect((res as TextFileOk).fileName, '购物清单.csv');
    });
  });
}
