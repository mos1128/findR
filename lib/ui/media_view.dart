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
/// 光靠底色在深色模式下几乎与卡片同色，会被看成「坏掉的黑框」（真机反馈）。
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

/// 全屏相册：**同一个卡片的多张照片，左右滑动就能切换**。
///
/// ⚠️ **必须一次拿到整组**（`PageView`）—— 只画一张的话，「看第二张」的唯一办法是
/// **退出去、再点第二张缩略图**，那不是少个手势，是条死路（真机反馈
/// 「同一个卡片中的两张图不能左右滑动切换」说的就是这个）。
/// 并且**从点的那张开始**（`initialIndex`）。
Future<void> openImageViewer(
  BuildContext context,
  List<String> relPaths, {
  int initialIndex = 0,
}) {
  if (relPaths.isEmpty) return Future<void>.value();
  final start = initialIndex.clamp(0, relPaths.length - 1);
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _ImageViewer(relPaths: relPaths, initialIndex: start),
    ),
  );
}

/// 一张大图（点开进全屏相册，可以左右滑）。
///
/// ⚠️ **当前没有被接进界面**：卡片详情的照片走的是「缩略图条 + 全屏相册」
/// （见 `card_detail_screen.dart` 的「照片」段）。留着是因为「单张大图」的版式
/// 迟早要用（比如把首图直接放大显示），删了还得重写。要用就直接摆上去。
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
        ),
        alignment: Alignment.center,
        child: Text('图片不在了', style: TextStyle(fontSize: 12.5, color: c.textMuted)),
      );
    }
    return GestureDetector(
      onTap: () => openImageViewer(context, <String>[relPath]),
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

/// 全屏相册本体。
///
/// 标题里的「2 / 3」不是装饰 —— 它是**唯一说明「这里能左右滑」的显式线索**。
/// 只有一张时不显示：没有可翻的页，那个数字纯属噪音。
class _ImageViewer extends StatefulWidget {
  const _ImageViewer({required this.relPaths, required this.initialIndex});

  final List<String> relPaths;
  final int initialIndex;

  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
  late final PageController _page = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.relPaths.length;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          total > 1 ? '查看图片（${_index + 1} / $total）' : '查看图片',
          style: const TextStyle(fontSize: 15),
        ),
      ),
      body: PageView.builder(
        controller: _page,
        itemCount: total,
        // 页码**只在这里**更新。别去监听 controller：拖动过程中会反复 setState，
        // 而这里除了标题没有任何东西需要跟手刷新。
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (_, i) => _ImagePage(relPath: widget.relPaths[i]),
      ),
    );
  }
}

/// 相册里的一页。
///
/// 每一页**都必须占住自己那一页**，哪怕文件读不出来 —— 否则「第 2 张丢了」
/// 会表现成「总数少一张」，页码和内容就错位了。
class _ImagePage extends StatelessWidget {
  const _ImagePage({required this.relPath});

  final String relPath;

  @override
  Widget build(BuildContext context) {
    final file = mediaFileOf(relPath);
    if (file == null) return const _MissingImage();
    // ⚠️ 用 `SizedBox.expand` 铺满整页，**不要**用 `Center` 直接把 `Image` 包起来：
    // 图片还没解码完时 `Image` 的固有尺寸是 0，`InteractiveViewer` 会跟着变成 0×0，
    // 于是「在图上拖动」根本落不到它身上（页面看着正常、就是划不动）。
    // 铺满之后 `BoxFit.contain` 自己会把图居中、按比例装进去，两边留黑边反而更像相册。
    return InteractiveViewer(
      minScale: 1,
      maxScale: 5,
      // 没放大时没有可拖的余量，手势应当落到 PageView 上；
      // 「没放大就左右滑翻页、放大后拖动看图」这两件事不能打架。见下面那条拖动用例。
      child: SizedBox.expand(
        child: Image.file(
          file,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const _MissingImage(),
        ),
      ),
    );
  }
}

class _MissingImage extends StatelessWidget {
  const _MissingImage();

  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('图片不在了', style: TextStyle(color: Colors.white70)));
}

