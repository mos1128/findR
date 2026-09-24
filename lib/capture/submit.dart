/// 落盘 + 插行。
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

/// 一张选取的图片（支持选图时即刻上屏，压缩完全在后台异步处理）。
final class PendingPhoto {
  PendingPhoto({
    Uint8List? rawBytes,
    Uint8List? webp,
    this.width = 0,
    this.height = 0,
    this.compressFuture,
  })  : rawBytes = rawBytes ?? webp ?? Uint8List(0),
        _webp = webp;

  /// 原始选取的图片字节（用于无需等待的极速缩略图渲染，或作为后备）。
  final Uint8List rawBytes;

  /// 已压缩编码的 WebP 字节；若后台任务仍在压缩则初始为 null。
  Uint8List? _webp;
  Uint8List get webp => _webp ?? rawBytes;

  /// 后台异步压缩的任务。
  Future<void>? compressFuture;

  /// 压缩后的尺寸，仅用于回显与调试。
  int width;
  int height;

  /// 大概多少 KB，界面拿来显示「3 张 · 约 640KB」。
  int get approxKb => ((_webp?.length ?? rawBytes.length) / 1024).round();

  bool get isCompressed => _webp != null;

  void setCompressed({required Uint8List webp, required int width, required int height}) {
    _webp = webp;
    this.width = width;
    this.height = height;
  }
}

/// 一个待保存的文件附件。
final class PendingFile {
  PendingFile({
    required this.name,
    required this.bytes,
    this.text,
    bool? includeContent,
  }) : includeContent = includeContent ?? (text != null && text.trim().isNotEmpty);

  final String name;
  final Uint8List bytes;

  /// 可解码为文本时的内容；若为 null 表示二进制或不可读文本。
  final String? text;

  /// 是否将内容提取并追加到记忆文本中由模型分析。
  bool includeContent;

  bool get isReadable => text != null && text!.trim().isNotEmpty;
  int get sizeKb => (bytes.length / 1024).round();
  int get charCount => text?.length ?? 0;
}

/// 一次录入要落库的东西。
final class CaptureSubmission {
  const CaptureSubmission({
    this.text,
    this.photos = const <PendingPhoto>[],
    this.audio,
    this.attachments = const <PendingFile>[],
  });

  final String? text;
  final List<PendingPhoto> photos;

  /// 还躺在临时目录里的录音；由 [persistCapture] 负责搬进媒体目录并删掉临时文件。
  final RecordedAudio? audio;

  /// 附件文件列表。
  final List<PendingFile> attachments;
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

  // 3) 附件：存入卡片附件子目录
  for (final att in input.attachments) {
    final attRel = 'files/cards/${monthDir(at)}/$cardId/attachments/${att.name}';
    writeMediaFile(attRel, att.bytes);
  }

  // 4) 来源由「手里真有什么」决定，不是由用户从哪个入口进来的
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
