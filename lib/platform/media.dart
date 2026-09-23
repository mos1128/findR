/// 真机上的文件访问 —— core 那两个端口的设备实现。
///
/// 结构：上面是给两个端口共用的小函数，下面分别是 `MediaIo`
/// （面向「送模型」的读法：base64 / multipart）与
/// `MediaStorePort`（面向备份的「字节进字节出」）。
///
/// 两个端口分开是有意的：接口形状不同，混成一个会让两边都别扭。
library;

import 'dart:typed_data';

import 'package:findr_core/findr_core.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'app_paths.dart';

/// 按后缀猜 MIME。**别加这张表之外的猜测**，
/// 多猜一种就等于多一个「本地能传、真机传不了」的不对称。
String mimeFromRel(String rel) {
  final name = rel.split('/').last;
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  switch (ext) {
    case 'webp':
      return 'image/webp';
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'm4a':
      return 'audio/m4a';
    case 'wav':
      return 'audio/wav';
    default:
      return 'application/octet-stream';
  }
}

String fileNameOf(String rel) {
  final parts = rel.split('/').where((s) => s.isNotEmpty).toList();
  return parts.isEmpty ? 'file' : parts.last;
}

/// 写媒体文件，自动补建父目录。**先写文件、再插行**靠它保证原子性。
void writeMediaFile(String rel, List<int> content) {
  final dir = AppPaths.parentOf(rel);
  if (dir != null && !dir.existsSync()) dir.createSync(recursive: true);
  // flush: true —— 写完立刻可读（自检与导入都紧接着读回同一路径）。
  AppPaths.file(rel).writeAsBytesSync(content, flush: true);
}

bool mediaExists(String rel) => AppPaths.file(rel).existsSync();

/// 回放用的绝对 URI（播放器要 `file://`）。
String mediaUri(String rel) => Uri.file(AppPaths.abs(rel)).toString();

/// core 的 [MediaIo] 在设备端的实现。
///
/// **`audioPart` 的两个性质**：用 `MultipartFile.fromPath`，走的是**文件流**
/// （不把 m4a 整个读进内存），并且**尊重调用方给的 filename**
/// —— core 的注释说得很清楚：服务端常靠后缀嗅探格式，名字不能由实现方随便定。
final class DeviceMediaIo implements MediaIo {
  const DeviceMediaIo();

  @override
  Future<ImageData> imageData(String rel) async {
    final file = AppPaths.file(rel);
    if (!file.existsSync()) throw StateError('图片文件不存在：$rel');
    return ImageData(
      base64: bytesToBase64(await file.readAsBytes()),
      mime: mimeFromRel(rel),
    );
  }

  @override
  Future<http.MultipartFile> audioPart(String rel, String mime, String filename) async {
    final file = AppPaths.file(rel);
    if (!file.existsSync()) throw StateError('音频文件不存在：$rel');
    return http.MultipartFile.fromPath(
      'file', // 上传字段名固定是 file（OpenAI 兼容协议的规定）
      file.path,
      filename: filename,
      contentType: MediaType.parse(mime),
    );
  }

  @override
  String fileUri(String rel) => mediaUri(rel);

  @override
  Future<void> removeCardMedia(List<String> relPaths) async {
    for (final rel in relPaths) {
      try {
        final file = AppPaths.file(rel);
        if (file.existsSync()) file.deleteSync();
      } catch (_) {
        // 单个文件删不掉不该阻塞其余回收
      }
    }
  }
}

/// core 的 [MediaStorePort] 在设备端的实现（备份用）：相对路径 ↔ 沙盒里的真实文件。
///
/// **不实现「删」**：备份只读不删，导入也不动本地多余媒体（设计约定「不删除本地任何数据」）。
/// 这里同样不需要 `removeCardMedia` —— 那是 [DeviceMediaIo] 的事（删草稿时回收）。
final class DeviceMediaStore implements MediaStorePort {
  const DeviceMediaStore();

  @override
  Future<Uint8List?> read(String relPath) async {
    final file = AppPaths.file(relPath);
    // 文件不存在返回 null 而不是抛错：DB 可能引用已被回收、或拍完没保存的路径
    if (!file.existsSync()) return null;
    return file.readAsBytes();
  }

  @override
  void write(String relPath, Uint8List data) => writeMediaFile(relPath, data);

  @override
  bool Function(String relPath)? get exists => mediaExists;
}
