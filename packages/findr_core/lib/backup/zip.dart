/// 最小 ZIP 读写（**只支持 STORE，不压缩**）。
///
/// 为什么不用现成的 ZIP 包 / `dart:io` 的 gzip：
///   - 媒体（webp / m4a）本身已是压缩格式，deflate 在这里几乎不省字节，却要拖进来一个依赖；
///   - core 的既定约束是**零平台依赖、能力全走注入**（不引第三方 zip 库：
///     Dart 侧 `dart:io` 其实有 zlib，但用了它就等于把 core 绑死在非 Web 平台）；
///   - STORE 是 ZIP 规范里最简单的一档，写+读不到 250 行，且产物是**标准 zip**，
///     用户拿 7-Zip 就能打开自检（调试价值）。
///
/// 读取侧**刻意只认 method=0**：本格式只由我们自己写，遇到 deflate 说明文件被人重新压过，
/// 与其猜不如直接报错 —— **解不开的包比悄悄导入一半更危险**。
library;

import 'dart:async';
import 'dart:typed_data';

import 'crc32.dart';

const int _localSig = 0x04034b50;
const int _centralSig = 0x02014b50;
const int _eocdSig = 0x06054b50;

const int _methodStore = 0;

/// bit 11 = 文件名按 UTF-8 解释；我们的名字全是 ASCII，置上只是为了让别的工具不猜错。
const int _flagUtf8 = 0x0800;
const int _versionNeeded = 20;
const int _maxU32 = 0xffffffff;
const int _eocdMin = 22;
const int _maxComment = 0xffff;

/// 一个待写入成员的**计划**：长度与 CRC 必须由调用方先算好。
///
/// 这样 [buildZip] 才能一次性分配输出缓冲（从而把峰值内存压到「输出 + 单个文件」）。
final class ZipEntryPlan {
  const ZipEntryPlan({required this.path, required this.size, required this.crc32});

  /// 包内路径，**必须 ASCII**（我们的用法是 `manifest.json` 与 `files/...`）。
  final String path;

  final int size;
  final int crc32;
}

final class ZipReadEntry {
  const ZipReadEntry({required this.path, required this.data});

  final String path;

  /// 包内数据的**零拷贝视图**。
  final Uint8List data;
}

/// 名字只走 ASCII 单字节编解码。
///
/// 不用平台自带的编码 API，理由：
/// **文件名本来就不需要多字节**，而一旦允许非 ASCII，包内路径在不同 ZIP 工具下会出现编码歧义。
Uint8List _encodeName(String name) {
  final out = Uint8List(name.length);
  for (var i = 0; i < name.length; i++) {
    final code = name.codeUnitAt(i);
    if (code > 0x7f) {
      throw FormatException('备份包内路径含非 ASCII 字符：$name');
    }
    out[i] = code;
  }
  return out;
}

String _decodeName(Uint8List bytes) {
  final buf = StringBuffer();
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] > 0x7f) {
      throw const FormatException('备份包内出现非 ASCII 路径，无法解析');
    }
    buf.writeCharCode(bytes[i]);
  }
  return buf.toString();
}

/// ZIP 的 DOS 时间戳：秒只存偶数（2 秒精度），年份从 1980 起算。
///
/// ⚠️ 必须显式 `toLocal()` —— 这个字段按规范是**本地时间**，
/// 否则传进来一个 UTC 的 `DateTime`（带 `isUtc` 标记）会得到 UTC 的时分秒。
/// 这个时间戳只影响解压工具里显示的「修改时间」，
/// 但它同样是**格式的一部分** —— 按标准实现，产物才能被通用解压工具打开。
({int time, int date}) _dosDateTime(DateTime d) {
  final local = d.toLocal();
  final time = ((local.hour << 11) | (local.minute << 5) | (local.second >> 1)) & 0xffff;
  final year = local.year - 1980;
  final date = (((year < 0 ? 0 : year) << 9) | (local.month << 5) | local.day) & 0xffff;
  return (time: time, date: date);
}

/// 按 entries 的 path/size 算出整包精确长度（含中央目录与 EOCD）。
int planZipSize(List<ZipEntryPlan> entries) {
  var total = _eocdMin;
  for (final e in entries) {
    final nameLen = _encodeName(e.path).length;
    total += 30 + nameLen + e.size; // local header + name + 数据
    total += 46 + nameLen; // central directory 条目
  }
  return total;
}

/// 按 entries 里已声明的 size/crc32 组装 zip。
///
/// 数据通过 [readEntry] 按需取 —— 这样调用方可以「每个文件读一次就写进去」，
/// 峰值内存只有「输出缓冲 + 单个文件」，而不是把所有媒体同时握在手里。
/// [readEntry] 允许返回 `Future`：设备端读文件是异步的，这里顺序 await 即可。
Future<Uint8List> buildZip(
  List<ZipEntryPlan> entries,
  FutureOr<Uint8List> Function(String path) readEntry,
  DateTime mtime,
) async {
  final stamp = _dosDateTime(mtime);
  final names = entries.map((e) => _encodeName(e.path)).toList();
  final total = planZipSize(entries);
  if (total > _maxU32) {
    throw StateError('备份包超过 4GB，当前 ZIP 写入器不支持 ZIP64');
  }

  final out = Uint8List(total);
  final view = ByteData.view(out.buffer);
  var p = 0;
  final offsets = <int>[];

  void u16(int v) {
    view.setUint16(p, v, Endian.little);
    p += 2;
  }

  void u32(int v) {
    view.setUint32(p, v, Endian.little);
    p += 4;
  }

  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    final name = names[i];
    offsets.add(p);

    u32(_localSig);
    u16(_versionNeeded);
    u16(_flagUtf8);
    u16(_methodStore);
    u16(stamp.time);
    u16(stamp.date);
    u32(e.crc32);
    u32(e.size);
    u32(e.size);
    u16(name.length);
    u16(0);
    out.setAll(p, name);
    p += name.length;

    final data = await readEntry(e.path);
    if (data.length != e.size) {
      throw StateError('媒体文件在两次读取之间变长/变短了：${e.path}');
    }
    out.setAll(p, data);
    p += data.length;
  }

  final cdOffset = p;
  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    final name = names[i];
    u32(_centralSig);
    u16(_versionNeeded);
    u16(_versionNeeded);
    u16(_flagUtf8);
    u16(_methodStore);
    u16(stamp.time);
    u16(stamp.date);
    u32(e.crc32);
    u32(e.size);
    u32(e.size);
    u16(name.length);
    u16(0); // extra
    u16(0); // comment
    u16(0); // disk start
    u16(0); // internal attrs
    u32(0); // external attrs
    u32(offsets[i]);
    out.setAll(p, name);
    p += name.length;
  }
  final cdSize = p - cdOffset;

  u32(_eocdSig);
  u16(0);
  u16(0);
  u16(entries.length);
  u16(entries.length);
  u32(cdSize);
  u32(cdOffset);
  u16(0);

  if (p != total) {
    throw StateError('ZIP 组装长度不符：预期 $total，实际 $p');
  }
  return out;
}

int _findEocd(Uint8List bytes) {
  final rawMin = bytes.length - (_eocdMin + _maxComment);
  final min = rawMin < 0 ? 0 : rawMin;
  for (var i = bytes.length - _eocdMin; i >= min; i--) {
    if (bytes[i] == (_eocdSig & 0xff) &&
        bytes[i + 1] == ((_eocdSig >> 8) & 0xff) &&
        bytes[i + 2] == ((_eocdSig >> 16) & 0xff) &&
        bytes[i + 3] == ((_eocdSig >> 24) & 0xff)) {
      return i;
    }
  }
  throw const FormatException('备份包内容不是有效 ZIP：找不到中央目录结尾');
}

/// 读出全部成员。**每个成员都验 CRC32** —— 这是明文方案唯一的完整性兜底。
List<ZipReadEntry> readZip(Uint8List bytes) {
  final view = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes);
  final eocd = _findEocd(bytes);
  final count = view.getUint16(eocd + 10, Endian.little);
  final cdOffset = view.getUint32(eocd + 16, Endian.little);
  final cdSize = view.getUint32(eocd + 12, Endian.little);
  if (cdOffset + cdSize > bytes.length) {
    throw const FormatException('备份包内容不是有效 ZIP：中央目录越界');
  }

  final out = <ZipReadEntry>[];
  var p = cdOffset;
  for (var i = 0; i < count; i++) {
    if (view.getUint32(p, Endian.little) != _centralSig) {
      throw const FormatException('备份包内容不是有效 ZIP：中央目录条目损坏');
    }
    final method = view.getUint16(p + 10, Endian.little);
    final expectedCrc = view.getUint32(p + 16, Endian.little);
    final size = view.getUint32(p + 24, Endian.little);
    final nameLen = view.getUint16(p + 28, Endian.little);
    final extraLen = view.getUint16(p + 30, Endian.little);
    final commentLen = view.getUint16(p + 32, Endian.little);
    final localOffset = view.getUint32(p + 42, Endian.little);
    final name = _decodeName(Uint8List.sublistView(bytes, p + 46, p + 46 + nameLen));
    p += 46 + nameLen + extraLen + commentLen;

    if (method != _methodStore) {
      throw FormatException('备份包内 $name 使用了压缩存储（method=$method），本实现只支持 STORE');
    }
    if (view.getUint32(localOffset, Endian.little) != _localSig) {
      throw FormatException('备份包内容不是有效 ZIP：$name 的本地头损坏');
    }
    final localNameLen = view.getUint16(localOffset + 26, Endian.little);
    final localExtraLen = view.getUint16(localOffset + 28, Endian.little);
    final dataStart = localOffset + 30 + localNameLen + localExtraLen;
    if (dataStart + size > bytes.length) {
      throw FormatException('备份包内容不是有效 ZIP：$name 数据越界');
    }

    final data = Uint8List.sublistView(bytes, dataStart, dataStart + size);
    if (crc32(data) != expectedCrc) {
      throw FormatException('备份包内 $name 校验和不符，文件已损坏');
    }
    out.add(ZipReadEntry(path: name, data: data));
  }
  return out;
}
