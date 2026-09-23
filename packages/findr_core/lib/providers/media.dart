/// core 的文件访问端口 —— 逐字对应 `packages/core/src/providers/media.ts`（14 行）。
///
/// core 自身**零文件 IO**：TS 侧 node 给 Blob、RN 给 `{uri,name,type}`，两边各自只认自己那种
/// FormData part，所以 `audioPart` 的返回类型只能写 `unknown`。
///
/// **Dart 侧的偏离：`audioPart` 返回具体的 `http.MultipartFile`。**
/// 理由：Dart 只有一个运行时，`unknown` 那种「谁实现谁负责转型」的洞没有必要保留；
/// 返回真实类型后，调用点不用 `as`，端口实现方也能直接用 `MultipartFile.fromPath`
/// （**走文件流，不把 m4a 整个读进内存** —— 这正是 TS 原注释要保住的性质）。
/// 代价是 `providers/` 这一层和 `package:http` 绑定了：可接受，它本来就叫 `providers`。
library;

import 'package:http/http.dart' as http;

/// 图片的 inline 数据。图片**必须**内联成 base64 才能进视觉模型。
final class ImageData {
  const ImageData({required this.base64, required this.mime});

  /// 裸 base64，**不含** `data:` 前缀（前缀由适配器按协议自己拼）。
  final String base64;

  final String mime;
}

/// core 需要的全部文件能力。由 App 侧实现（仓库根的 `lib/platform/` 里接文件系统），core 只调用。
abstract interface class MediaIo {
  /// 读成 inline base64（视觉模型要的形态）。
  Future<ImageData> imageData(String rel);

  /// 返回可直接进 multipart 的音频 part。
  ///
  /// [rel] 是 App 沙盒内的相对路径；[mime] 是上传用的 MIME；
  /// [filename] 由调用方决定（**服务端常靠后缀嗅探格式**，所以不能由实现方随便定）。
  /// 上传字段名固定是 `file`（OpenAI 兼容协议的规定）。
  ///
  /// 实现应走 `MultipartFile.fromPath` 之类的流式路径，**不要把 m4a 整体读进内存**。
  Future<http.MultipartFile> audioPart(String rel, String mime, String filename);

  /// 回放用的绝对 URI（播放器要 `file://`）。
  String fileUri(String rel);

  /// 删除卡片的媒体文件（删草稿时回收）。
  Future<void> removeCardMedia(List<String> relPaths);
}
