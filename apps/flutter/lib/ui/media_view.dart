/// 媒体显示 —— 缩略图与大图。
///
/// DB 里存的是**相对路径**（见 `findr_core` 的 `media/paths.dart`），
/// 绝对路径由 `platform/app_paths.dart` 拼。所以这里的每一处都要先问一句
/// 「沙盒就绪了吗」：`AppPaths` 没 init 时（widget 测试、启动前）读路径会抛，
/// 而一个缩略图读不出来绝不该把整屏炸掉。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../platform/app_paths.dart';
import '../theme/tokens.dart';

/// 把一个相对路径读成 `File`；不可用时返回 null（**不抛**）。
File? mediaFileOf(String rel) {
  if (!AppPaths.ready) return null;
  try {
    return AppPaths.file(rel);
  } catch (_) {
    return null;
  }
}

/// 方角缩略图。文件不存在 / 沙盒未就绪 → 显示带边框的占位块。
///
/// ⚠️ 占位块**必须有轮廓 + 有内容（来源图标）**：
/// 光靠底色在深色模式下几乎与卡片同色，会被看成「坏掉的黑框」（RN 那边的真机反馈）。
class MediaThumb extends StatelessWidget {
  const MediaThumb({
    super.key,
    this.relPath,
    this.fallbackIcon = '📷',
    this.size = 68,
  });

  /// null / 空 ⇒ 直接显示占位块。
  final String? relPath;
  final String fallbackIcon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final file = relPath == null || relPath!.isEmpty ? null : mediaFileOf(relPath!);

    Widget placeholder() => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      alignment: Alignment.center,
      child: Text(fallbackIcon, style: TextStyle(fontSize: size * 0.38)),
    );

    if (file == null) return placeholder();

    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.md),
      child: Image.file(
        file,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // 文件被回收 / 备份里引用了没还原的路径 —— 退回占位块，别让红叉铺满列表
        errorBuilder: (_, _, _) => placeholder(),
      ),
    );
  }
}

/// 全屏看一张图（可缩放）。给缩略图条用 —— 详情页里的照片要能点开看清。
Future<void> openImageViewer(BuildContext context, String relPath) => Navigator.of(context).push(
  MaterialPageRoute<void>(builder: (_) => _ImageViewer(relPath: relPath)),
);

/// 卡片详情里的大图。点开可以放大（简单的全屏相册）。
class MediaFull extends StatelessWidget {
  const MediaFull({super.key, required this.relPath});

  final String relPath;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final file = mediaFileOf(relPath);
    if (file == null || !file.existsSync()) {
      return Container(
        height: 180,
        decoration: BoxDecoration(
          color: c.surfaceAlt,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: c.border),
        ),
        alignment: Alignment.center,
        child: Text('图片不在了', style: TextStyle(fontSize: 12.5, color: c.textMuted)),
      );
    }
    return GestureDetector(
      onTap: () => openImageViewer(context, relPath),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.md),
        child: Image.file(
          file,
          fit: BoxFit.cover,
          width: double.infinity,
          errorBuilder: (_, _, _) => Container(
            height: 180,
            color: c.surfaceAlt,
            alignment: Alignment.center,
            child: Text('图片读不出来', style: TextStyle(fontSize: 12.5, color: c.textMuted)),
          ),
        ),
      ),
    );
  }
}

class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.relPath});

  final String relPath;

  @override
  Widget build(BuildContext context) {
    final file = mediaFileOf(relPath);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('查看图片', style: TextStyle(fontSize: 15)),
      ),
      body: Center(
        child: file == null
            ? const Text('图片不在了', style: TextStyle(color: Colors.white70))
            : InteractiveViewer(
                minScale: 1,
                maxScale: 5,
                child: Image.file(file, fit: BoxFit.contain),
              ),
      ),
    );
  }
}
