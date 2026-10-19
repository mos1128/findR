/// 图片压缩那一层的验收网。
///
/// 这一层是**纯计算**（不碰平台通道），所以能在 `flutter test` 里跑 ——
/// 也就是说「压出来的到底是不是 WebP、长边有没有真的收到 1600、有没有偷偷压成无损、
/// 竖着拍的照片会不会存成横的」这些问题不必等上真机才有答案。
///
/// 其中两条是这个文件存在的**主要理由**（都是 `image` 包的默认行为埋的雷）：
///
/// 1. **`encodeWebP` 默认无损**，而无损模式下 `quality` 被完全忽略。
///    只写 `quality: 80` 会得到一个参数看着对、体积却大一倍以上、且毫无报错的文件。
/// 2. **`decodeImage` 解 JPEG 时不读 EXIF**，于是 `bakeOrientation` 读不到方向、
///    原样返回 —— 手机竖着拍一张，存下来是横的，同样一句报错都没有。
library;

import 'dart:math' as math;

import 'package:findr_app/capture/image_compress.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// 造一张**照片感**的图（渐变 + 颗粒）。
///
/// 为什么要掺颗粒：纯渐变是**周期性**的（`% 256` 每 256 像素重复一次），
/// 无损编码能把它压得比有损还小 —— 那样「无损 vs 有损」的体积对比会因为图太规整而失去意义
/// （实测确实出现过：同一张图无损 1848 字节、有损 22724 字节）。
/// 加一点确定性颗粒之后，无损压不动、有损能糊掉一部分，对比才有意义。
Uint8List photoLikeJpg(int width, int height) {
  final im = img.Image(width: width, height: height);
  var seed = 123456789;
  int noise() {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
    return (seed >> 16) % 25 - 12; // ±12
  }

  for (final p in im) {
    p
      ..r = (128 + 90 * math.sin(p.x / 47.0) + noise()).round().clamp(0, 255)
      ..g = (128 + 90 * math.sin(p.y / 31.0) + noise()).round().clamp(0, 255)
      ..b = (128 + 90 * math.sin((p.x + p.y) / 59.0) + noise()).round().clamp(0, 255);
  }
  return img.encodeJpg(im, quality: 95);
}

/// 一张普通 PNG（用来验「非 JPEG 也能压」，以及非图像的拒绝路径）。
Uint8List plainPng(int width, int height) {
  final im = img.Image(width: width, height: height);
  img.fill(im, color: img.ColorRgb8(90, 140, 190));
  return img.encodePng(im);
}

/// 给一张 JPEG 塞进指定的 EXIF 方向标记。
///
/// 只能借 `image` 包自己的 `injectJpgExif`：`encodeJpg` 写出来的 EXIF **读不回来**
/// （它的解码器不读 APP1），所以「造一张带方向的图」这条路非这么走不可。
Uint8List jpgWithOrientation(int width, int height, int orientation) {
  final base = photoLikeJpg(width, height);
  final exif = img.ExifData()..imageIfd.orientation = orientation;
  final tagged = img.injectJpgExif(base, exif);
  expect(tagged, isNotNull, reason: 'injectJpgExif 没成功，这条用例没法验');
  return tagged!;
}

void main() {
  group('长边与尺寸', () {
    test('长边超过 1600 的图压到 1600，另一边按比例', () {
      final ok = compressToWebp(photoLikeJpg(1800, 1200)) as CompressOk;
      expect(ok.width, 1600);
      expect(ok.height, 1067); // 1200 × 1600/1800
      expect(ok.longEdge, 1600);
    });

    test('竖图按高度收到 1600', () {
      final ok = compressToWebp(photoLikeJpg(1200, 2000)) as CompressOk;
      expect(ok.height, 1600);
      expect(ok.width, 960);
    });

    test('本来就不大的图**不放大**（放大只会白占空间）', () {
      final ok = compressToWebp(photoLikeJpg(800, 600)) as CompressOk;
      expect(ok.width, 800);
      expect(ok.height, 600);
    });

    test('正好 1600 的图原样不动', () {
      final ok = compressToWebp(photoLikeJpg(1600, 900)) as CompressOk;
      expect(ok.longEdge, 1600);
      expect(ok.width, 1600);
    });

    test('PNG 源一样能压（不是只有相机 JPEG 走得通）', () {
      final ok = compressToWebp(plainPng(400, 300)) as CompressOk;
      expect(isWebp(ok.webp), isTrue);
      expect(ok.width, 400);
    });
  });

  group('格式', () {
    test('产出的是 WebP（RIFF/WEBP 魔数）', () {
      final ok = compressToWebp(photoLikeJpg(400, 300)) as CompressOk;
      expect(isWebp(ok.webp), isTrue, reason: '头 12 字节不是 RIFF....WEBP');
      expect(ok.webp.length, greaterThan(12));
    });

    test('产出的 WebP 能被读回来，且尺寸与报告一致', () {
      final ok = compressToWebp(photoLikeJpg(1700, 1200)) as CompressOk;
      final decoded = img.decodeImage(ok.webp);
      expect(decoded, isNotNull);
      expect(decoded!.width, ok.width);
      expect(decoded.height, ok.height);
    });
  });

  group('有损（这条最要紧）', () {
    test('**确实是有损** —— 必须明显小于同一张图的无损 WebP', () {
      final source = photoLikeJpg(1200, 900);
      final decoded = img.decodeImage(source)!;
      // 同一个内存对象、同一个编码器，**只差那个 flag** ⇒ 差异只可能来自 lossless
      final losslessBytes = img.encodeWebP(decoded, lossless: true).length;
      final ok = compressToWebp(source) as CompressOk;

      expect(
        ok.webp.length,
        lessThan(losslessBytes),
        reason:
            '压出来不小于无损 ⇒ 几乎可以肯定 `lossless: false` 没生效。'
            '`image` 包的 encodeWebP 默认无损，且无损时 quality 被忽略。',
      );
      // 要求是「明显更小」而不是「小一点点」
      expect(ok.webp.length * 2, lessThan(losslessBytes));
    });

    test('参数就是 maxLongEdge / webpQuality / 非无损这三件', () {
      // 这三个常量是写死的口径，改动必须是有意识的
      expect(maxLongEdge, 1600);
      expect(webpQuality, 80);
      expect(webpLossless, isFalse);
    });
  });

  group('EXIF 方向（解码器已经转正，别再转第二遍）', () {
    test('带方向标记的 JPEG：**解码时就已经摆正了**，且方向标记被清掉', () {
      final tagged = jpgWithOrientation(1200, 600, 6);
      final decoded = img.decodeImage(tagged)!;
      expect(decoded.width, 600, reason: '解码器没转正 ⇒ 下面几条都会跟着错');
      expect(decoded.height, 1200);
      // 关键：转正之后 orientation 被清成 null。这正是「解出来的图 exif 是空的」的原因，
      // 不是「漏读了」—— 一旦误判成漏读、自己补一次 EXIF，就会转第二遍。
      expect(decoded.exif.imageIfd.hasOrientation, isFalse);
    });

    test('竖拍照存下来还是竖的（600×1200，不是 1200×600）', () {
      final ok = compressToWebp(jpgWithOrientation(1200, 600, 6)) as CompressOk;
      expect(ok.width, 600);
      expect(ok.height, 1200);
      expect(
        ok.width,
        isNot(1200),
        reason: '转了两遍 ⇒ 又变回横的。别在这里自己用 decodeJpgExif 补一次方向。',
      );
    });

    test('orientation 8（逆时针 90°）同样只转一遍', () {
      final ok = compressToWebp(jpgWithOrientation(1200, 600, 8)) as CompressOk;
      expect(ok.width, 600);
      expect(ok.height, 1200);
    });

    test('orientation 1（本来就正）的图不受影响', () {
      final ok = compressToWebp(jpgWithOrientation(1200, 600, 1)) as CompressOk;
      expect(ok.width, 1200);
      expect(ok.height, 600);
    });

    test('不带 EXIF 的普通 JPEG 也走同一条路', () {
      final ok = compressToWebp(photoLikeJpg(1200, 600)) as CompressOk;
      expect(ok.width, 1200);
      expect(ok.height, 600);
    });
  });

  group('拒绝的几种', () {
    test('空字节给一句人话', () {
      final r = compressToWebp(Uint8List(0));
      expect(r, isA<CompressFailed>());
      expect((r as CompressFailed).reason, contains('空的'));
    });

    test('不是图片的字节：说「读不出来」', () {
      final r = compressToWebp(Uint8List.fromList(List<int>.filled(64, 7)));
      expect(r, isA<CompressFailed>());
      expect((r as CompressFailed).reason, contains('读不了'));
    });

    test('超过单张上限：直接拒绝，且把上限说出来', () {
      final r = compressToWebp(Uint8List(maxSourceBytes + 1));
      expect(r, isA<CompressFailed>());
      expect((r as CompressFailed).reason, contains('上限'));
    });

    test('HEIC：要**点名**这个格式并给绕行办法（笼统说「读不出来」等于没说）', () {
      // 造一个真实形状的 ftyp box：4 字节长度 + 'ftyp' + brand
      final heic = Uint8List.fromList(<int>[
        0, 0, 0, 0x18,
        0x66, 0x74, 0x79, 0x70, // 'ftyp'
        0x68, 0x65, 0x69, 0x63, // 'heic'
        ...List<int>.filled(16, 0),
      ]);
      expect(isHeic(heic), isTrue);

      final r = compressToWebp(heic) as CompressFailed;
      expect(r.reason, contains('HEIC'));
      expect(r.reason, contains('兼容性最佳'));
    });

    test('isHeic 不会误判，也不会被太短的输入骗到', () {
      expect(isHeic(photoLikeJpg(40, 40)), isFalse);
      expect(isHeic(plainPng(40, 40)), isFalse);
      expect(isHeic(Uint8List(3)), isFalse);
      // JPEG 是 FFD8 开头，别跟 ISO-BMFF 的 ftyp 混了
      expect(photoLikeJpg(40, 40).take(2).toList(), <int>[0xFF, 0xD8]);
    });
  });

  group('跨 isolate', () {
    test('compute() 能把结果对象送回来（真机上就是这么调的）', () async {
      final ok = await compute(compressToWebp, photoLikeJpg(400, 300));
      expect(ok, isA<CompressOk>());
      expect(isWebp((ok as CompressOk).webp), isTrue);
    });

    test('失败结果同样能跨 isolate（不能靠抛异常传话）', () async {
      final r = await compute(compressToWebp, Uint8List(0));
      expect(r, isA<CompressFailed>());
    });
  });
}
