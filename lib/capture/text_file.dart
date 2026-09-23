/// 纯文本文件读入 —— 对应 RN 的 `capture/files.ts`。
///
/// 需求 5.1（第十七版新增）：从底部输入条的「＋」里挑一个文本文件，**本地读成文字**后
/// 与打字完全同一条链路。
///
/// 三条硬口径：
///
/// 1. **只支持纯文本类扩展名**（`txt / md / markdown / json / csv / tsv / log / yaml / yml`）。
///    **PDF / Word 不做** —— 要额外引入原生解析依赖，且各家模型对 `file` 内容块的支持不一致，
///    会打破架构原则 R2。这类内容请截图（走图片路径）或直接复制文字进来。
/// 2. 单文件上限 **8000 字**，**超限不静默截断**，而是明确拒绝并告知实际字数。
///    「静默截断」是最坏的一种失败：用户以为整份进去了。
/// 3. 读不出来要**说清是哪一步失败**（扩展名不支持 / 编码不对 / 文件读不了），
///    别把它们混成一句含糊话。
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';

/// 允许的扩展名（小写，不带点）。
const List<String> plainTextExtensions = <String>[
  'txt',
  'md',
  'markdown',
  'json',
  'csv',
  'tsv',
  'log',
  'yaml',
  'yml',
];

/// 单文件字符上限。
const int maxPlainTextChars = 8000;

/// 读文件的结果。用 sealed 而不是抛异常：每一条失败都有**不同的话要说**，
/// 而调用点就在界面里、本来就是要把这句话显示出来。
sealed class TextFileResult {
  const TextFileResult();
}

final class TextFileOk extends TextFileResult {
  const TextFileOk(this.text, this.fileName);

  final String text;
  final String fileName;
}

final class TextFileRejected extends TextFileResult {
  const TextFileRejected(this.message);

  /// 一句能直接给用户看的话。
  final String message;
}

/// 从 [PlatformFile] 读出文本。
Future<TextFileResult> readPlainTextFile(PlatformFile file) async {
  return decodePlainText(
    name: file.name,
    readBytes: file.xFile.readAsBytes,
  );
}

/// 真正的判定逻辑，与「文件从哪来」解耦。
///
/// 刻意收成这个形状：`PlatformFile` 是个不好在测试里手工构造的第三方类型，
/// 若把逻辑写死在 [readPlainTextFile] 里，这 9 条扩展名规则 + 8000 字上限就只能在
/// 真机上用真文件试 —— 那等于没有覆盖。这里只依赖「名字 + 读字节」两件事。
Future<TextFileResult> decodePlainText({
  required String name,
  required Future<List<int>> Function() readBytes,
}) async {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  if (!plainTextExtensions.contains(ext)) {
    return TextFileRejected(
      '只支持纯文本文件（${plainTextExtensions.join(' / ')}）。'
      'PDF / Word 这类请改成截图发我，或者把文字复制进来。',
    );
  }

  String text;
  try {
    text = utf8.decode(await readBytes());
  } catch (e) {
    // 编码不对是常态（Windows 记事本存的 GBK、Excel 导出的 GB18030）
    return const TextFileRejected('这个文件不是 UTF-8 编码的文本，读不出来。可以另存为 UTF-8 再试。');
  }

  // 去掉 BOM，否则会变成一个看不见的字符跟着标题走
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const TextFileRejected('这个文件是空的。');

  // ⚠️ **不截断**：超限就明确拒绝并告诉实际字数（需求 5.1）
  if (trimmed.length > maxPlainTextChars) {
    return TextFileRejected(
      '这个文件有 ${trimmed.length} 字，超过 $maxPlainTextChars 字的上限了。'
      '可以拆成几个文件，或者直接截取需要的部分粘进来。',
    );
  }

  return TextFileOk(trimmed, name);
}

/// 打开选择器挑一个文本文件。
///
/// 与备份那边同理：**用 `FileType.any` 而不是按扩展名过滤**。
/// Android 的 SAF 对扩展名的判定常常不认（同一个 txt 从不同 App 存过来 MIME 都不一样），
/// 一旦限定就会出现「文件明明在、选择器里却是灰的」。把关交给 [decodePlainText] 的扩展名检查。
Future<PlatformFile?> pickPlainTextFile() =>
    FilePicker.pickFile(dialogTitle: '选择一个文本文件');
