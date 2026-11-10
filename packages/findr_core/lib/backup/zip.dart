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
import 'types.dart';

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

/// 流式读取时的一个成员头（中央目录信息 + 本地头位置）。
///
/// [localOffset] 是**整份源里的绝对偏移**（含 `.findrpack` 的容器头）。
final class ZipEntryHeader {
  const ZipEntryHeader({
    required this.path,
    required this.crc,
    required this.size,
    required this.localOffset,
  });

  final String path;
  final int crc;
  final int size;
  final int localOffset;
}

/// 从随机访问源读中央目录，得到全部成员头。
///
/// 只读 EOCD 与中央目录（都是元数据），媒体数据一个字节都不碰。
/// [baseOffset] 是 ZIP 载荷在源文件里的起点（`.findrpack` 的 7 字节头）。
Future<List<ZipEntryHeader>> readZipDirectory(
  BackupByteSource source, {
  int baseOffset = 0,
}) async {
  final total = await source.length();
  final zipLength = total - baseOffset;
  if (zipLength < _eocdMin) {
    throw const FormatException('备份包内容不是有效 ZIP：找不到中央目录结尾');
  }
  final tailLen = zipLength < _eocdMin + _maxComment
      ? zipLength
      : _eocdMin + _maxComment;
  final tail = await _readExact(source, total - tailLen, tailLen);
  final eocd = _findEocd(tail);
  final view = ByteData.view(tail.buffer, tail.offsetInBytes, tail.lengthInBytes);
  final count = view.getUint16(eocd + 10, Endian.little);
  final cdSize = view.getUint32(eocd + 12, Endian.little);
  final cdOffset = view.getUint32(eocd + 16, Endian.little);
  if (cdOffset + cdSize > zipLength) {
    throw const FormatException('备份包内容不是有效 ZIP：中央目录越界');
  }
  if (count == 0) return <ZipEntryHeader>[];

  final cd = await _readExact(source, baseOffset + cdOffset, cdSize);
  final cdView = ByteData.view(cd.buffer, cd.offsetInBytes, cd.lengthInBytes);
  final out = <ZipEntryHeader>[];
  var p = 0;
  for (var i = 0; i < count; i++) {
    if (p + 46 > cd.length) {
      throw const FormatException('备份包内容不是有效 ZIP：中央目录条目损坏');
    }
    if (cdView.getUint32(p, Endian.little) != _centralSig) {
      throw const FormatException('备份包内容不是有效 ZIP：中央目录条目损坏');
    }
    final method = cdView.getUint16(p + 10, Endian.little);
    final crc = cdView.getUint32(p + 16, Endian.little);
    final size = cdView.getUint32(p + 24, Endian.little);
    final nameLen = cdView.getUint16(p + 28, Endian.little);
    final extraLen = cdView.getUint16(p + 30, Endian.little);
    final commentLen = cdView.getUint16(p + 32, Endian.little);
    final localOffset = cdView.getUint32(p + 42, Endian.little);
    final end = p + 46 + nameLen + extraLen + commentLen;
    if (end > cd.length) {
      throw const FormatException('备份包内容不是有效 ZIP：中央目录条目越界');
    }
    final name = _decodeName(
      Uint8List.sublistView(cd, p + 46, p + 46 + nameLen),
    );
    p = end;

    if (method != _methodStore) {
      throw FormatException('备份包内 $name 使用了压缩存储（method=$method），本实现只支持 STORE');
    }
    if (baseOffset + localOffset + 30 > total) {
      throw FormatException('备份包内容不是有效 ZIP：$name 的本地头越界');
    }
    out.add(
      ZipEntryHeader(
        path: name,
        crc: crc,
        size: size,
        localOffset: baseOffset + localOffset,
      ),
    );
  }
  return out;
}

/// 读出一个成员的完整数据（只占一个成员的内存，不加载整包）。
Future<Uint8List> readZipEntry(
  BackupByteSource source,
  ZipEntryHeader entry, {
  required int totalLength,
  int chunkSize = 64 * 1024,
}) async {
  final data = await _readEntry(
    source,
    entry,
    totalLength: totalLength,
    keep: true,
    chunkSize: chunkSize,
  );
  return data!;
}

/// 只校验一个成员的 CRC，不保留数据。流式导入的第一遍用它。
Future<void> verifyZipEntry(
  BackupByteSource source,
  ZipEntryHeader entry, {
  required int totalLength,
  int chunkSize = 64 * 1024,
}) => _readEntry(
  source,
  entry,
  totalLength: totalLength,
  keep: false,
  chunkSize: chunkSize,
);

Future<Uint8List?> _readEntry(
  BackupByteSource source,
  ZipEntryHeader entry, {
  required int totalLength,
  required bool keep,
  required int chunkSize,
}) async {
  final head = await _readExact(source, entry.localOffset, 30);
  final view = ByteData.view(head.buffer, head.offsetInBytes, head.lengthInBytes);
  if (view.getUint32(0, Endian.little) != _localSig) {
    throw FormatException('备份包内容不是有效 ZIP：${entry.path} 的本地头损坏');
  }
  if (view.getUint16(8, Endian.little) != _methodStore) {
    throw FormatException('备份包内 ${entry.path} 的本地头不是 STORE');
  }
  final nameLen = view.getUint16(26, Endian.little);
  final extraLen = view.getUint16(28, Endian.little);
  final dataStart = entry.localOffset + 30 + nameLen + extraLen;
  if (dataStart + entry.size > totalLength) {
    throw FormatException('备份包内容不是有效 ZIP：${entry.path} 数据越界');
  }

  final builder = keep ? BytesBuilder(copy: false) : null;
  final crc = Crc32();
  var offset = dataStart;
  var remaining = entry.size;
  while (remaining > 0) {
    final want = remaining < chunkSize ? remaining : chunkSize;
    final chunk = await source.read(offset, want);
    if (chunk.isEmpty) {
      throw FormatException('备份包内容不完整：${entry.path} 提前结束');
    }
    if (chunk.length > remaining) {
      throw FormatException('备份包内容不完整：${entry.path} 数据超出声明长度');
    }
    builder?.add(chunk);
    crc.add(chunk);
    offset += chunk.length;
    remaining -= chunk.length;
  }
  if (crc.value != entry.crc) {
    throw FormatException('备份包内 ${entry.path} 校验和不符，文件已损坏');
  }
  return builder?.takeBytes();
}

/// 读满 [count] 字节；源允许返回短块，这里负责续读。
Future<Uint8List> _readExact(
  BackupByteSource source,
  int offset,
  int count,
) async {
  final builder = BytesBuilder(copy: false);
  var got = 0;
  while (got < count) {
    final chunk = await source.read(offset + got, count - got);
    if (chunk.isEmpty) {
      throw const FormatException('备份文件读取不完整');
    }
    builder.add(chunk);
    got += chunk.length;
  }
  return builder.takeBytes();
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

/// 流式写 ZIP 的字节出口。同步/异步都行：文件写盘用异步可以自然背压。
typedef ZipChunkWriter = FutureOr<void> Function(Uint8List bytes);

/// 流式 ZIP 写入器。
///
/// 产出与 [buildZip] **逐字节同格式**（STORE、成员头里直接写 size/crc、无 data descriptor），
/// 区别只是不再一次性分配整包缓冲：调用方先流式算一遍每个成员的 size/crc，
/// 再流式写一遍数据。峰值内存 = 单个读块，与媒体总量无关。
final class ZipStreamWriter {
  ZipStreamWriter({required this.write, required DateTime mtime})
    : _stamp = _dosDateTime(mtime);

  final ZipChunkWriter write;
  final ({int time, int date}) _stamp;
  final List<({Uint8List name, int crc, int size, int offset})> _entries = <({
    Uint8List name,
    int crc,
    int size,
    int offset,
  })>[];
  int _offset = 0;

  /// 已写出的 ZIP 字节数（不含容器头）。
  int get bytesWritten => _offset;

  /// 写入一段已知内容的成员（manifest 走这里）。
  Future<void> addBytes(String path, Uint8List data) async {
    final crc = crc32(data);
    final name = _encodeName(path);
    final offset = _offset;
    await _writeLocalHeader(name, data.length, crc);
    await write(data);
    _offset += data.length;
    _entries.add((
      name: name,
      crc: crc,
      size: data.length,
      offset: offset,
    ));
  }

  /// 写入一个流式成员。`size` / `crc` 必须由调用方先算好（见 `pack.dart` 的两遍流式读）。
  Future<void> addFile(
    String path, {
    required int size,
    required int crc,
    required Stream<List<int>> data,
  }) async {
    if (size > _maxU32) {
      throw StateError('备份内文件超过 4GB，当前 ZIP 写入器不支持 ZIP64：$path');
    }
    final name = _encodeName(path);
    final offset = _offset;
    await _writeLocalHeader(name, size, crc);

    var seen = 0;
    final actual = Crc32();
    await for (final chunk in data) {
      final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      seen += bytes.length;
      if (seen > size) throw StateError('媒体文件在导出过程中变大了：$path');
      actual.add(bytes);
      await write(bytes);
      _offset += bytes.length;
    }
    if (seen != size) throw StateError('媒体文件在导出过程中变短了：$path');
    if (actual.value != crc) throw StateError('媒体文件在导出过程中内容变了：$path');
    _entries.add((
      name: name,
      crc: crc,
      size: size,
      offset: offset,
    ));
  }

  /// 写中央目录与 EOCD。调用后不应再 add。
  Future<void> finish() async {
    if (_offset > _maxU32) {
      throw StateError('备份包超过 4GB，当前 ZIP 写入器不支持 ZIP64');
    }
    if (_entries.length > 0xffff) {
      throw StateError('备份包成员超过 65535，当前 ZIP 写入器不支持 ZIP64');
    }
    final cdOffset = _offset;
    for (final e in _entries) {
      final central = Uint8List(46 + e.name.length);
      final view = ByteData.view(central.buffer);
      var p = 0;
      void u16(int v) {
        view.setUint16(p, v, Endian.little);
        p += 2;
      }

      void u32(int v) {
        view.setUint32(p, v, Endian.little);
        p += 4;
      }

      u32(_centralSig);
      u16(_versionNeeded);
      u16(_versionNeeded);
      u16(_flagUtf8);
      u16(_methodStore);
      u16(_stamp.time);
      u16(_stamp.date);
      u32(e.crc);
      u32(e.size);
      u32(e.size);
      u16(e.name.length);
      u16(0); // extra
      u16(0); // comment
      u16(0); // disk start
      u16(0); // internal attrs
      u32(0); // external attrs
      u32(e.offset);
      central.setAll(p, e.name);
      await write(central);
      _offset += central.length;
    }
    final cdSize = _offset - cdOffset;

    final eocd = Uint8List(_eocdMin);
    final view = ByteData.view(eocd.buffer);
    var p = 0;
    void u16(int v) {
      view.setUint16(p, v, Endian.little);
      p += 2;
    }

    void u32(int v) {
      view.setUint32(p, v, Endian.little);
      p += 4;
    }

    u32(_eocdSig);
    u16(0);
    u16(0);
    u16(_entries.length);
    u16(_entries.length);
    u32(cdSize);
    u32(cdOffset);
    u16(0);
    await write(eocd);
    _offset += eocd.length;
  }

  Future<void> _writeLocalHeader(Uint8List name, int size, int crc) async {
    if (crc < 0 || crc > _maxU32 || size > _maxU32) {
      throw StateError('ZIP 字段超出 32 位范围');
    }
    final header = Uint8List(30 + name.length);
    final view = ByteData.view(header.buffer);
    var p = 0;
    void u16(int v) {
      view.setUint16(p, v, Endian.little);
      p += 2;
    }

    void u32(int v) {
      view.setUint32(p, v, Endian.little);
      p += 4;
    }

    u32(_localSig);
    u16(_versionNeeded);
    u16(_flagUtf8);
    u16(_methodStore);
    u16(_stamp.time);
    u16(_stamp.date);
    u32(crc);
    u32(size);
    u32(size);
    u16(name.length);
    u16(0);
    header.setAll(p, name);
    await write(header);
    _offset += header.length;
  }
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

/// 读出全部成员。**每个成员都验 CRC32** —— 这是本格式唯一的完整性兜底。
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
