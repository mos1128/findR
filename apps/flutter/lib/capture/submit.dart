/// 落盘 + 插行 —— 对应 RN 的 `capture/submit.ts`（73 行）+ `compress.ts` 的写文件那一半。
///
/// **顺序是硬约束：先把文件写进媒体目录，再插卡片的行。**
/// 反过来的话，中间任何一步失败都会留下一条「有记录、没素材」的卡片 ——
/// 而这条卡片既搜不到也修不好，正是「素材永不丢失」这条红线要防的东西。
///
/// 图片**在这里只写不压**：压缩在用户选图的那一刻就做完了（见 `image_compress.dart`），
/// 交给这里的是已经压好的 WebP 字节。这样「落盘」永远是几十毫秒的事，
/// 而不会让用户按了「存」之后盯着转圈等一组图片编码。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:findr_core/findr_core.dart';

import '../platform/media.dart';
import 'recorder.dart';

/// 一张已经压好、等着落盘的图片。
final class PendingPhoto {
  const PendingPhoto({required this.webp, required this.width, required this.height});

  /// 已编码的 WebP 字节。
  final Uint8List webp;

  /// 压缩后的尺寸，仅用于回显与调试。
  final int width;
  final int height;

  /// 大概多少 KB，界面拿来显示「3 张 · 约 640KB」。
  int get approxKb => (webp.length / 1024).round();
}

/// 一次录入要落库的东西。
final class CaptureSubmission {
  const CaptureSubmission({this.text, this.photos = const <PendingPhoto>[], this.audio});

  final String? text;
  final List<PendingPhoto> photos;

  /// 还躺在临时目录里的录音；由 [persistCapture] 负责搬进媒体目录并删掉临时文件。
  final RecordedAudio? audio;
}

/// 落盘 + 插行，返回草稿卡。调用方拿到就可以立刻渲染，**不必等模型**。
///
/// [id] 一般由调用方生成（媒体路径里含 cardId）；不给就现场生成一个。
Future<MemoryCard> persistCapture(
  SqliteDriver db,
  CaptureSubmission input, {
  String? id,
  DateTime? now,
}) async {
  final cardId = id ?? makeId();
  final at = now ?? DateTime.now();

  // 1) 图片：路径由 core 算（`files/cards/<yyyymm>/<id>/01.webp`），顺序即拍摄顺序
  final imageRels = <String>[];
  for (var i = 0; i < input.photos.length; i++) {
    final rel = imageRelPath(at, cardId, i);
    writeMediaFile(rel, input.photos[i].webp);
    imageRels.add(rel);
  }

  // 2) 录音：从临时目录搬进来
  String? audioRel;
  final audio = input.audio;
  if (audio != null) {
    audioRel = audioRelPath(at, cardId);
    writeMediaFile(audioRel, await File(audio.tempPath).readAsBytes());
    // 搬完就删临时文件；删不掉也无所谓（它在临时目录里，系统会清）
    try {
      final tmp = File(audio.tempPath);
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {
      // 忽略
    }
  }

  // 3) 来源由「手里真有什么」决定，不是由用户从哪个入口进来的
  //    （需求里没有「文件」这个来源，文本文件走的就是文字链路）
  final text = (input.text ?? '').trim();
  final SourceKind source;
  if (imageRels.isNotEmpty) {
    source = SourceKind.photo;
  } else if (audioRel != null) {
    source = SourceKind.voice;
  } else {
    source = SourceKind.text;
  }

  return createDraft(
    db,
    CaptureInput(
      source: source,
      text: text.isEmpty ? null : text,
      images: imageRels.isEmpty ? null : imageRels,
      audio: audioRel,
    ),
    id: cardId,
    now: at,
  );
}

/// 图片超过软阈值时的那句提示文案（需求 5.1：**只提示确认，不做硬截断**）。
/// 没超返回 null。
String? overImageLimitHint(int count) => count > maxCaptureImagesWarn
    ? '这条已经有 $count 张图（建议不超过 $maxCaptureImagesWarn 张）。继续也可以，只是会更占存储。'
    : null;
