/// 图片入库压缩。
///
/// 只做一件事：**任意常见图片字节 → 长边 ≤1600px 的有损 WebP 字节**。
/// 这是纯计算、不碰平台通道，所以能在 `flutter test` 里直接验，
/// 不必等上真机才知道「压出来的到底是不是 WebP」。
///
/// 这个包里有**两个**必须自己扛住的坑，都写在下面各自的注释里，这里先点一下：
/// 1. `encodeWebP` 默认 `lossless: true`，而无损模式下 `quality` **被完全忽略**；
/// 2. EXIF 方向**已经由 JPEG 解码器烤进像素了**，自己再补一次会把照片转两遍。
///    （第二条是「以为漏了、其实没漏」的那一类，注释里连实测现象一起写了。）
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 入库压缩参数：长边 ≤1600px、WebP quality 0.8。
const int maxLongEdge = 1600;

/// ⚠️⚠️ **必须和 `lossless: false` 一起用** —— `image` 包的 `encodeWebP` 默认是
/// **无损**，而 `quality` 在无损模式下**被完全忽略**。
///
/// 也就是说只写 `encodeWebP(x, quality: 80)` 会得到一个「参数看着对了、
/// 其实是无损」的 WebP：体积可能翻倍以上，而且**一点报错都不会有**。
/// 这不是猜的 —— 包自己的源码注释就写着：
/// 「`encodeWebP(image, quality: 40)` on its own does nothing at all:
/// pass `lossless: false` first.」
///
/// 另：WebP 的 quality 与 JPEG 的 quality **不是同一把尺子**（同一注释里也写了），
/// 所以这个 80 只是「大致等同于 JPEG 0.8 的意图」，不是「与 JPEG 80 等画质」。
const int webpQuality = 80;

/// 无损/有损分水岭。见 [webpQuality]。
const bool webpLossless = false;

/// 单张图片的原始字节上限。
///
/// 这是**护栏**不是产品规则：解码一张 12MP 的 JPEG 会展开成约 48MB 的 RGBA，
/// 手上同时留几张就足以在低端机上 OOM。宁可给一句人话，也不要崩。
const int maxSourceBytes = 32 * 1024 * 1024;

/// 压缩结果。**刻意不用异常**：它要跨 isolate 回来（`compute`），
/// 用一个封闭的返回值表达成败，比让异常穿越 isolate 边界稳当。
sealed class CompressResult {
  const CompressResult();
}

final class CompressOk extends CompressResult {
  const CompressOk({required this.webp, required this.width, required this.height, required this.longEdge});

  /// 编好的 WebP 字节，可直接落盘。
  final Uint8List webp;

  /// 压缩后的像素尺寸（用于「已处理 1600×1200」这类回显）。
  final int width;
  final int height;

  /// 压缩后的长边，便于界面/测试直接断言。
  final int longEdge;
}

final class CompressFailed extends CompressResult {
  const CompressFailed(this.reason);

  /// 给用户看的人话。
  final String reason;
}

/// 把一张图片压成入库用的 WebP。
///
/// 顶层函数，可以直接喂给 `compute()` 跑在后台 isolate 上
/// （解码 + 缩放 + 编码在 1600px 这一档是几百毫秒量级，放主线程会掉帧）。
CompressResult compressToWebp(Uint8List source) {
  if (source.isEmpty) return const CompressFailed('这个图片文件是空的。');
  if (source.length > maxSourceBytes) {
    return CompressFailed(
      '这张图有 ${(source.length / (1024 * 1024)).toStringAsFixed(1)}MB，超过了单张 '
      '${maxSourceBytes ~/ (1024 * 1024)}MB 的上限。',
    );
  }

  final img.Image? decoded;
  try {
    decoded = img.decodeImage(source);
  } catch (e) {
    return CompressFailed('这张图没能读出来：$e');
  }
  if (decoded == null) {
    // 解不出来的最常见原因是 HEIC（iPhone 直出的格式）。
    // 与其笼统说「读不出来」，不如把这一种点名 —— 它有明确的绕行办法。
    if (isHeic(source)) {
      return const CompressFailed('这是 iPhone 的 HEIC 格式，暂时读不了。可以在系统设置里把相机改成「兼容性最佳」，或先截图再选。');
    }
    return const CompressFailed('这张图没能读出来（不是常见的 JPEG / PNG / WebP 格式）。');
  }

  // ⚠️⚠️ **这一段刻意什么都不做** —— 写下来免得下次又来「补一刀」。
  //
  // 表面上看这里该自己读一次 EXIF：`decodeImage` 出来的对象 `exif` 是空的，
  // 而 `bakeOrientation` 靠 `image.exif` 判方向，读不到就原样返回，像是漏了。
  // 于是很自然会写上「用 `decodeJpgExif` 取回方向 → 赋给 `decoded.exif`」。
  //
  // **那会把照片转两遍。** `image` 包的 JPEG 路径（`_jpeg_quantize_io.dart`）在解码时
  // 就已经读了 EXIF 方向、把像素转正、并**把 orientation 清成 null** ——
  // 这正是「解出来的图 exif 是空的」的原因，不是漏读。
  // 补一刀的实测结果：1200×600 的竖拍照 → 解码已是 600×1200 → 又被转回 1200×600。
  // 白忙一场，而且一句报错都没有。
  //
  // 那为什么还留着下面这行 `bakeOrientation`？因为**别的格式不一定**：
  // PNG 的 `eXIf` 分块是解码器挂到 `image.exif` 上的（`png_decoder.dart`），
  // 那种图就真的需要这一步才转正。对已经转正的图它是空转，不影响。
  final upright = img.bakeOrientation(decoded);

  final longEdge = upright.width >= upright.height ? upright.width : upright.height;
  final scaled = longEdge > maxLongEdge
      // 只给长边，另一边由它按比例算 —— 避免自己算出个差一像素的比值
      ? (upright.width >= upright.height
            ? img.copyResize(upright, width: maxLongEdge, interpolation: img.Interpolation.linear)
            : img.copyResize(upright, height: maxLongEdge, interpolation: img.Interpolation.linear))
      : upright;

  final Uint8List webp;
  try {
    webp = img.encodeWebP(
      scaled,
      lossless: webpLossless,
      quality: webpQuality,
      // method 0~6：0 为极速编码档，不跑耗时的全块穷举搜索，耗时下降 80%+
      method: 0,
    );
  } catch (e) {
    return CompressFailed('这张图压不了：$e');
  }

  final outW = scaled.width;
  final outH = scaled.height;
  return CompressOk(webp: webp, width: outW, height: outH, longEdge: outW >= outH ? outW : outH);
}

/// 是不是 HEIC / HEIF。判的是 ISO-BMFF 的 `ftyp` box，不是文件后缀
/// （相册选出来的临时文件常常没有后缀）。
bool isHeic(Uint8List bytes) {
  if (bytes.length < 12) return false;
  // box 类型固定在第 4~8 字节
  if (bytes[4] != 0x66 || bytes[5] != 0x74 || bytes[6] != 0x79 || bytes[7] != 0x70) {
    return false;
  }
  final brand = String.fromCharCodes(bytes.sublist(8, 12));
  return const <String>{
    'heic',
    'heix',
    'hevc',
    'hevx',
    'heim',
    'heis',
    'hevm',
    'hevs',
    'mif1',
    'msf1',
  }.contains(brand);
}

/// 反过来判一下 WebP（测试与自检用）。`RIFF....WEBP`。
bool isWebp(Uint8List bytes) {
  if (bytes.length < 12) return false;
  return bytes[0] == 0x52 && // R
      bytes[1] == 0x49 && // I
      bytes[2] == 0x46 && // F
      bytes[3] == 0x46 && // F
      bytes[8] == 0x57 && // W
      bytes[9] == 0x45 && // E
      bytes[10] == 0x42 && // B
      bytes[11] == 0x50; // P
}
