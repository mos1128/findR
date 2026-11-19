/// 「按住说话」的壳：按下就报、上滑就取消、松手就结束。
///
/// 这里**不判「轻点还是长按」**：只有语音态才用得上它，点一下本来也没有别的含义。
/// 所以按下立刻回调，不等任何阈值 —— 说话的第一句不该被「按稳判定」吃掉。
/// 太短的录音由 `shouldDiscardRecording`（`capture/recorder.dart`）在松手时判为误触丢掉。
library;

import 'package:flutter/widgets.dart';

/// 按住说话的手势壳。
class HoldInput extends StatefulWidget {
  const HoldInput({
    super.key,
    required this.child,
    required this.onHoldStart,
    required this.onHoldEnd,
    required this.onCancelChanged,
    this.enabled = true,
  });

  /// 药丸本身。画什么由调用方定（提示语 / 录音态 / 听到的那句）。
  final Widget child;

  /// 按下。**立即**回调，不等阈值。
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
  /// 上滑进取消区要 64，退回来只用 44：同一个边界上抖一下不该来回报警。
  static const double _enterCancel = 64;
  static const double _exitCancel = 44;

  double? _startY;
  bool _pressed = false;
  bool _cancelling = false;

  void _down(PointerDownEvent e) {
    if (!widget.enabled) return;
    _pressed = true;
    _startY = e.position.dy;
    _cancelling = false;
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
    // 松手这里**不许**补一个 `onCancelChanged(false)`：调用方是在 [onHoldEnd] 里
    // 看自己那份取消态的，先清掉就等于把这次取消吞了 —— 划上去松手照样把录音存下来。
    _cancelling = false;
    widget.onHoldEnd();
  }

  @override
  Widget build(BuildContext context) => Listener(
    // 药丸两边的留白也算按住了：手指常常落在字的外面，
    // 那片空白不接手势的话，用户会以为「这颗按不动」。
    behavior: HitTestBehavior.opaque,
    onPointerDown: _down,
    onPointerMove: _move,
    onPointerUp: (_) => _up(),
    onPointerCancel: (_) => _up(),
    child: widget.child,
  );
}
