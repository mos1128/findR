/// `.findrpack` 容器。
///
/// 布局：
///
///   magic "FINDR"(5B) + format version u16 (=1) + 载荷（标准 ZIP，STORE 不压缩）
///
/// ⚠️ **不做任何加密**：载荷就是原样的 ZIP，
/// 拿到文件的人用任何解压工具都能直接读到全部记忆。所以导出/导入的界面必须
/// 把这件事说清楚，别让用户以为它是加密的。
///
/// 那为什么还留这 7 字节的头？为了**版本判别**：将来把加密加回来时，
/// 加密文件的载荷不再是 ZIP，读取侧需要一个可靠的判据来决定走哪条路。
/// 到时候把 [backupFormatVersion] 提到 2（载荷 = salt ‖ nonce_base ‖ 分块密文）即可，
/// **头本身不动**。**别在加加密之前动这个头** —— 现在改了，将来就没有判据可用。
///
/// 完整性：明文没有 GCM tag 兜底，靠 ZIP 每个成员的 CRC32（见 `zip.dart` 的 `readZip`）。
/// 也就是说「截断 / 写坏 / 传输出错」能被抓到（会明确报「校验和不符」），
/// 但「有人有意改过内容再改回 CRC」抓不到 —— 这是明文方案的固有代价，不是 bug。
library;

import 'dart:typed_data';

const String backupMagic = 'FINDR';

/// 1 = 明文 ZIP 载荷。加密回归时提为 2，载荷格式另定。
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

/// 校验头并取出版本号。头不对 / 版本不认 / 文件被截断都在这里抛。
void _decodeHeader(Uint8List bytes) {
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
  _decodeHeader(bytes);
  return Uint8List.sublistView(bytes, backupHeaderLen);
}
