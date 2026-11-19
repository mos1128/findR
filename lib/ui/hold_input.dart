/// 「没唤起键盘时轻点聚焦、长按说话」的手势壳。
///
/// 键盘起来之后一切照旧 —— 长按就是选词，这里一个手势都不许抢。
/// 所以这个壳只在**未聚焦**时接管指针：聚焦时它一个手势都不接。
/// 键盘被返回键收起后焦点还在，那属于「输入态」还是「语音态」由调用方判定
/// （见 `Composer` / `SearchScreen` 里的 `didChangeMetrics`）。
///
/// 用裸指针事件而不是 `onLongPress`：`onLongPress` 要等 500ms 才回调，
/// 那 500ms 正是用户开口的第一句。按下即报 [onHoldStart]，由调用方决定怎么「抢跑」。
///
/// 上滑取消用两档阈值（进 64 / 退 44）：单档会在边界上来回抖，
/// 用户明明还按在取消区里，状态却一闪一闪。
library;

import 'dart:async';

import 'package:flutter/material.dart';

class HoldInput extends StatefulWidget {
  const HoldInput({
    super.key,
    required this.focused,
    required this.child,
    required this.placeholder,
    required this.onTap,
    required this.onHoldStart,
    required this.onHoldEnd,
    required this.onCancelChanged,
    this.enabled = true,
  });

  /// 真实输入框现在有没有焦点。
  final bool focused;

  /// 聚焦后的真实输入框。
  final Widget child;

  /// 未聚焦时长得像输入框的那一层（画什么由调用方定：提示语、已有文字、录音态）。
  final Widget placeholder;

  /// 轻点 → 聚焦。
  final VoidCallback onTap;

  /// 按下（未聚焦时）。**立即**回调，不等长按阈值。
  final VoidCallback onHoldStart;

  /// 松手 / 指针被系统抢走。
  final VoidCallback onHoldEnd;

  /// 手指进了取消区（true）或退回正常区（false）。
  ///
  /// 松手时不会再补一个 `false` —— 最终判定在 [onHoldEnd] 里读。
  final ValueChanged<bool> onCancelChanged;

  final bool enabled;

  @override
  State<HoldInput> createState() => _HoldInputState();
}

class _HoldInputState extends State<HoldInput> {
  static const double _enterCancel = 64;
  static const double _exitCancel = 44;

  /// 按住超过这么久就不再算「轻点」。调用方一律在 200ms 后才开麦，
  /// 这条线跟它对齐：够得着开麦的那次按压，松手不该再补一次聚焦 ——
  /// 补了的结果是录完音键盘自己弹起来（把录音态又盖回去了）。
  static const Duration _tapMax = Duration(milliseconds: 200);

  double? _startY;
  bool _pressed = false;
  bool _cancelling = false;
  bool _held = false;
  Timer? _holdTimer;

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  void _down(PointerDownEvent e) {
    if (!widget.enabled || widget.focused) return;
    _pressed = true;
    _held = false;
    _startY = e.position.dy;
    _cancelling = false;
    _holdTimer?.cancel();
    _holdTimer = Timer(_tapMax, () => _held = true);
    widget.onHoldStart();
  }

  void _move(PointerMoveEvent e) {
    final startY = _startY;
    if (!_pressed || startY == null) return;
    final up = startY - e.position.dy;
    final next = _cancelling ? up > _exitCancel : up > _enterCancel;
    if (next == _cancelling) return;
    _cancelling = next;
    widget.onCancelChanged(next);
  }

  void _up() {
    if (!_pressed) return;
    _pressed = false;
    _startY = null;
    _holdTimer?.cancel();
    _holdTimer = null;
    // 松手这里**不许**补一个 `onCancelChanged(false)`：调用方是在 [onHoldEnd] 里
    // 看自己那份取消态的，先清掉就等于把这次取消吞了 —— 划上去松手照样把录音存下来。
    _cancelling = false;
    widget.onHoldEnd();
  }

  void _tap() {
    if (_held) return;
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    // 说明：真实输入框**必须一直在树上**。它不在树上，`_focus.requestFocus()`
    // 就没有任何可附着的焦点节点 —— 点一下没反应，键盘永远起不来（踩过）。
    // 所以未聚焦时不是「不画它」，而是用不透明的一层把它盖住，并先一步吃掉指针。
    final covered = !widget.focused;
    return Listener(
      onPointerDown: covered ? _down : null,
      onPointerMove: covered ? _move : null,
      onPointerUp: covered ? (_) => _up() : null,
      onPointerCancel: covered ? (_) => _up() : null,
      child: Stack(
        children: <Widget>[
          // 盖子是不透明的，底下这层得一起藏起来：两层同时画，文字就会在同一处叠着出现。
          Opacity(opacity: covered ? 0 : 1, child: widget.child),
          if (covered)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.enabled ? _tap : null,
                child: widget.placeholder,
              ),
            ),
        ],
      ),
    );
  }
}
