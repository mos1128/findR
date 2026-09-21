/// 录音回放条。
///
/// RN 那边卡片详情里的音频是**只读展示**（`app/card/[id].tsx` 只打了路径），
/// 于是「我录了什么」这件事用户是听不到的。这一版补上。
///
/// 两条刻意的做法：
/// 1. **文件不在就根本不建播放器**。DB 里的相对路径可能是「被回收过」或
///    「导入的备份里没有这个媒体文件」，这时候建一个播放器只会在 `play()` 时炸。
///    判在 Widget 层，界面直接说「录音文件不在了」。
/// 2. **播放器与 Widget 同生共死**（`dispose()` 里收掉）。播放器是原生资源，
///    退出这一页还留着它，就会出现「退出去了声音还在响」。
library;

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../platform/app_paths.dart';
import '../platform/media.dart';
import '../theme/tokens.dart';

/// 播放 [relPath] 指向的本地音频。`relPath` 是 core 的**相对路径**
/// （`files/audio/<yyyymm>/<id>.m4a`），绝对路径由 `AppPaths` 拼。
class AudioPlayBar extends StatefulWidget {
  const AudioPlayBar({super.key, required this.relPath, this.label});

  final String relPath;

  /// 左侧的一句话说明（比如「口述原文」）。
  final String? label;

  @override
  State<AudioPlayBar> createState() => _AudioPlayBarState();
}

class _AudioPlayBarState extends State<AudioPlayBar> {
  /// 文件不存在时**根本不建**（见文件头第 1 条）。
  AudioPlayer? _player;

  bool _exists = false;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _total = Duration.zero;

  /// 进度条实际宽度（`LayoutBuilder` 量的），点按跳转要用。
  double _trackWidth = 0;

  @override
  void initState() {
    super.initState();
    _exists = mediaExists(widget.relPath);
    if (_exists) _attach();
  }

  void _attach() {
    final p = AudioPlayer();
    _player = p;
    // 播完停在末尾、不释放音源 —— 这样「再播一次」不用重新准备
    unawaited(p.setReleaseMode(ReleaseMode.stop));
    p.onDurationChanged.listen((d) {
      if (mounted) setState(() => _total = d);
    });
    p.onPositionChanged.listen((d) {
      if (mounted) setState(() => _position = d);
    });
    p.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _playing = false;
        _position = Duration.zero;
      });
    });
  }

  @override
  void dispose() {
    _player?.dispose();
    _player = null;
    super.dispose();
  }

  Future<void> _toggle() async {
    final p = _player;
    if (p == null) return;
    try {
      if (_playing) {
        await p.pause();
        if (mounted) setState(() => _playing = false);
        return;
      }
      // `DeviceFileSource` 要的是**文件路径**（不是 file:// URI）
      await p.play(
        DeviceFileSource(AppPaths.abs(widget.relPath)),
        position: _position.inMilliseconds > 0 ? _position : null,
      );
      if (mounted) setState(() => _playing = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _playing = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('这段录音播不了：$e')));
    }
  }

  Future<void> _seekToFraction(double fraction) async {
    final p = _player;
    if (p == null || _total.inMilliseconds <= 0) return;
    final target = Duration(milliseconds: (_total.inMilliseconds * fraction).round());
    await p.seek(target);
    if (mounted) setState(() => _position = target);
  }

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);

    if (!_exists) {
      return _Shell(
        child: Row(
          children: <Widget>[
            Icon(Icons.graphic_eq_rounded, size: 18, color: c.textMuted),
            const SizedBox(width: Spacing.two),
            Expanded(
              child: Text(
                '这段录音的文件不在了（可能已被清理，或来自一份不含媒体的备份）。',
                style: TextStyle(fontSize: 11.5, height: 1.4, color: c.textMuted),
              ),
            ),
          ],
        ),
      );
    }

    final totalMs = _total.inMilliseconds <= 0 ? 1 : _total.inMilliseconds;
    final fraction = (_position.inMilliseconds / totalMs).clamp(0.0, 1.0);

    return _Shell(
      child: Row(
        children: <Widget>[
          Material(
            color: c.record,
            shape: const CircleBorder(),
            child: InkWell(
              onTap: _toggle,
              customBorder: const CircleBorder(),
              child: SizedBox(
                width: 38,
                height: 38,
                child: Icon(
                  _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 22,
                  color: c.recordText,
                ),
              ),
            ),
          ),
          const SizedBox(width: Spacing.three),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  widget.label ?? '录音',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.text),
                ),
                const SizedBox(height: Spacing.one),
                // 点进度条跳转。`onTapDown` 的 localPosition 就是相对这个手势区的，
                // 除以它自己的宽度即比例 —— 不需要任何坐标换算。
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) {
                    if (_trackWidth <= 0) return;
                    unawaited(_seekToFraction((d.localPosition.dx / _trackWidth).clamp(0.0, 1.0)));
                  },
                  child: SizedBox(
                    height: 20,
                    child: LayoutBuilder(
                      builder: (_, cons) {
                        _trackWidth = cons.maxWidth;
                        return Center(
                          child: SizedBox(
                            height: 4,
                            width: double.infinity,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: c.border,
                                borderRadius: BorderRadius.circular(Radii.pill),
                              ),
                              child: FractionallySizedBox(
                                alignment: Alignment.centerLeft,
                                widthFactor: fraction,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: c.record,
                                    borderRadius: BorderRadius.circular(Radii.pill),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: Spacing.three),
          Text(
            '${_fmt(_position)} / ${_fmt(_total)}',
            style: TextStyle(fontSize: 11, color: c.textSecondary),
          ),
        ],
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

/// 统一的底框：与卡片详情里其他「素材块」同一材质。
class _Shell extends StatelessWidget {
  const _Shell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: c.border),
      ),
      padding: const EdgeInsets.all(Spacing.three),
      child: child,
    );
  }
}
