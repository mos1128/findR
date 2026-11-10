/// `.findrpack` 容器。
///
/// 布局：
///
///   magic "FINDR"(5B) + format version u16 (=1) + 载荷（标准 ZIP，STORE 不压缩）
///
/// 那为什么还留这 7 字节的头？为了**版本判别**：读取侧据此决定怎么解释载荷，
/// 格式演进时把 [backupFormatVersion] 提上去即可，**头本身不动**。
///
/// 完整性：靠 ZIP 每个成员的 CRC32（见 `zip.dart` 的 `readZip`）。
/// 也就是说「截断 / 写坏 / 传输出错」能被抓到（会明确报「校验和不符」），
/// 但「有人有意改过内容再改回 CRC」抓不到 —— 这是这种方案的固有代价，不是 bug。
library;

import 'dart:typed_data';

const String backupMagic = 'FINDR';

/// 1 = ZIP 载荷。格式有变化时递增。
const int backupFormatVersion = 1;

/// 容器头长度：5 字节 magic + 2 字节 u16 版本 = 7。
const int backupHeaderLen = 5 + 2;

/// 拼出容器头（默认写当前版本）。
Uint8List encodeHeader([int formatVersion = backupFormatVersion]) {
  final out = Uint8List(backupHeaderLen);
  for (var i = 0; i < backupMagic.length; i++) {
    out[i] = backupMagic.codeUnitAt(i);
  }
  ByteData.view(out.buffer).setUint16(backupMagic.length, formatVersion, Endian.little);
  return out;
}

/// 校验头。头不对 / 版本不认 / 文件被截断都在这里抛。
///
/// 流式导入先读前 7 字节，也要走同一条校验。
void validateBackupHeader(Uint8List bytes) {
  if (bytes.length < backupHeaderLen) {
    throw const FormatException('备份文件过短，不是有效的 .findrpack');
  }
  for (var i = 0; i < backupMagic.length; i++) {
    if (bytes[i] != backupMagic.codeUnitAt(i)) {
      throw const FormatException('备份文件标识不符，不是 .findrpack 文件');
    }
  }
  final view = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes);
  final formatVersion = view.getUint16(backupMagic.length, Endian.little);
  if (formatVersion != backupFormatVersion) {
    throw FormatException(
      '备份格式版本 $formatVersion 不被支持（当前支持 $backupFormatVersion）',
    );
  }
}

/// 载荷 → 完整 `.findrpack` 字节（头 + 载荷）。**纯拼接，不做任何变换。**
Uint8List packContainer(Uint8List payload) {
  final header = encodeHeader();
  final out = Uint8List(header.length + payload.length);
  out.setAll(0, header);
  out.setAll(header.length, payload);
  return out;
}

/// `.findrpack` 字节 → 载荷（**零拷贝视图**）。
///
/// 头不对 / 版本不认 / 文件被截断都会在这里抛错。
Uint8List unpackContainer(Uint8List bytes) {
  validateBackupHeader(bytes);
  return Uint8List.sublistView(bytes, backupHeaderLen);
}
