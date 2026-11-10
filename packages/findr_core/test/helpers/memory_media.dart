/// 内存媒体库。
///
/// 让备份测试**完全不碰磁盘**：`MediaStorePort` 是注入进来的，
/// 所以「导出/导入到底写了哪些文件」是可断言的事实（[files] 就是那本账）。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:findr_core/findr_core.dart';

final class MemoryMedia implements MediaStorePort, StreamingMediaStore {
  MemoryMedia([Map<String, Uint8List> initial = const <String, Uint8List>{}]) {
    files.addAll(initial);
  }

  /// 相对路径 → 字节。测试直接读它来断言「文件到底写没写、写的是什么」。
  final Map<String, Uint8List> files = <String, Uint8List>{};

  @override
  FutureOr<Uint8List?> read(String relPath) => files[relPath];

  @override
  FutureOr<void> write(String relPath, Uint8List data) {
    files[relPath] = data;
  }

  @override
  FutureOr<bool> Function(String relPath)? get exists => (relPath) => files.containsKey(relPath);

  @override
  Stream<List<int>> openRead(String relPath) {
    final data = files[relPath];
    if (data == null) throw StateError('内存媒体库里没有 $relPath');
    // 故意切小块：让导出测试覆盖「跨块算 CRC / 跨块写盘」的路径
    return Stream<List<int>>.fromIterable(<List<int>>[
      for (var i = 0; i < data.length; i += 3)
        data.sublist(i, i + 3 > data.length ? data.length : i + 3),
    ]);
  }
}
