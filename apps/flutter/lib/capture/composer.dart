/// 底部录入条 —— 对应 RN 的 `capture/Composer.tsx`。
///
/// **这是「记」的唯一入口**（需求六）：打字 / 拍照 / 相册 / 文本文件 / 长按语音全在这一条里，
/// 不再有「两个按钮通到同一个页面」那种事。
///
/// 与 RN 版比，这一版的版式是新画的：底部做成一整块「坞」（圆角 + 上浮阴影），
/// 打字框与「存」不再分成两个视觉单元 —— 「记」是**一条**链路，
/// 界面上就不该长得像两个并列的功能。
///
/// ⚠️ **本块还没接上拍照 / 相册 / 长按录音**（需求 5.1 的媒体那半），
/// 那些要引入原生依赖（相机、压缩到 WebP、录音），单独作为一块做。
/// 现在能用的是两条完整的链路：**打字** 与 **纯文本文件**。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import '../ui/kit.dart';
import 'text_file.dart';

/// 一条待录入的内容。
///
/// `text` 与 `source` 分开：文本文件读进来的也是 `text`，但来源要如实记为文字
/// （需求里没有「文件」这个来源，它走的就是文字链路）。
final class ComposerPayload {
  const ComposerPayload({required this.text, this.fromFile = false});

  final String text;

  /// 是否来自「选文本文件」。只影响一句提示文案。
  final bool fromFile;
}

class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.onSubmit,
    this.enabled = true,

    /// 提交期间禁用整条（避免连点存出一堆重复卡）。
    this.busy = false,

    /// 上方要贴的提示（无网 / 未配 ASR 那类）。**放在坞的上边缘之内**，
    /// 与录入条同属一个视觉块，用户不会以为它是页面内容。
    this.notice,
  });

  final Future<void> Function(ComposerPayload payload) onSubmit;
  final bool enabled;
  final bool busy;
  final Widget? notice;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _sending = false;

  /// 「存」按钮的亮灭只取决于「输入框里有没有非空白内容」。
  ///
  /// ⚠️ 必须**自己记住上一次的值**再比。写成
  /// `if (has != _canSubmit) setState(...)` 会静默失效 ——
  /// `_canSubmit` 读的就是同一个 controller，新旧值永远是同一个数，
  /// 于是 `setState` 一次都不触发，「存」按钮永远不亮。
  /// （这个 bug 是被 `test/memory_stream_test.dart` 的录入用例抓出来的。）
  bool _hadText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    final has = _controller.text.trim().isNotEmpty;
    if (has != _hadText) {
      setState(() => _hadText = has);
    }
  }

  bool get _canSubmit => _hadText;

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _locked => widget.busy || _sending;

  /// 回车即存（与语音对等，一步落盘）。
  Future<void> _submitText() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _locked) return;
    setState(() => _sending = true);
    try {
      await widget.onSubmit(ComposerPayload(text: text));
      _controller.clear();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    // 录完一条继续留着键盘 —— 连着记几笔是常态，每存一条就收一次很烦
    if (mounted) _focus.requestFocus();
  }

  Future<void> _pickFile() async {
    if (_locked) return;
    final picked = await pickPlainTextFile();
    if (picked == null || !mounted) return;
    final result = await readPlainTextFile(picked);
    if (!mounted) return;
    switch (result) {
      case TextFileOk(:final text, :final fileName):
        setState(() => _sending = true);
        try {
          await widget.onSubmit(ComposerPayload(text: text, fromFile: true));
        } finally {
          if (mounted) setState(() => _sending = false);
        }
        if (mounted) {
          _toast('已从「$fileName」读入 ${text.length} 字，正在理解…');
        }
      case TextFileRejected(:final message):
        _toast(message);
    }
  }

  void _toast(String message) {
    final c = FindrColors.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, style: TextStyle(fontSize: 13, color: c.text)),
          backgroundColor: c.surface,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
  }

  Future<void> _openAttachSheet() async {
    if (_locked) return;
    final c = FindrColors.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.two),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(Spacing.five, Spacing.two, Spacing.five, Spacing.three),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '加素材',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: c.text,
                        ),
                      ),
                    ),
                    Text(
                      '已有文字会一起带上',
                      style: TextStyle(fontSize: 11.5, color: c.textMuted),
                    ),
                  ],
                ),
              ),
              ListRow(
                leading: const Text('📄', style: TextStyle(fontSize: 20)),
                title: '选文本文件',
                subtitle: '${plainTextExtensions.join(' / ')} · 单个不超过 $maxPlainTextChars 字',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_pickFile());
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Spacing.five, Spacing.two, Spacing.five, Spacing.three),
                child: Text(
                  '拍照、连拍、从相册选、长按录音还没接上 —— 那是下一块（要引入相机与音频依赖）。',
                  style: TextStyle(fontSize: 11.5, height: 1.4, color: c.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.border)),
        boxShadow: <BoxShadow>[
          BoxShadow(color: c.shadow, blurRadius: 12, offset: const Offset(0, -3)),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: maxContentWidth),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.four,
                Spacing.three,
                Spacing.four,
                Spacing.three,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (widget.notice != null) ...<Widget>[
                    widget.notice!,
                    const SizedBox(height: Spacing.three),
                  ],
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      _AttachButton(onPressed: widget.enabled ? _openAttachSheet : null),
                      const SizedBox(width: Spacing.two),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: c.surfaceAlt,
                            borderRadius: BorderRadius.circular(Radii.lg),
                            border: Border.all(color: c.border),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: Spacing.three,
                            vertical: Spacing.one,
                          ),
                          child: TextField(
                            controller: _controller,
                            focusNode: _focus,
                            enabled: widget.enabled && !_locked,
                            minLines: 1,
                            maxLines: 5,
                            textInputAction: TextInputAction.send,
                            // 打字回车即存（需求六）
                            onSubmitted: (_) => unawaited(_submitText()),
                            style: TextStyle(fontSize: 14.5, color: c.text),
                            decoration: InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              hintText: '记一笔…（回车即存）',
                              hintStyle: TextStyle(fontSize: 14, color: c.textMuted),
                              contentPadding: const EdgeInsets.symmetric(vertical: 10),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: Spacing.two),
                      _SaveButton(
                        enabled: widget.enabled && _canSubmit && !_locked,
                        loading: _sending,
                        onPressed: () => unawaited(_submitText()),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// ＋：展开加素材。**就地展开（弹一层），不跳页** —— 需求六明确要求。
class _AttachButton extends StatelessWidget {
  const _AttachButton({this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final on = onPressed != null;
    return Material(
      color: c.surfaceAlt,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
        side: BorderSide(color: c.border),
      ),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(Radii.lg),
        child: SizedBox(
          width: 46,
          height: 46,
          child: Icon(Icons.add_rounded, size: 24, color: on ? c.textSecondary : c.textMuted),
        ),
      ),
    );
  }
}

/// 「存」—— 整屏唯一用「记」的强调色实心块（需求六：与「查」强区分）。
class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.enabled, required this.loading, required this.onPressed});

  final bool enabled;
  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    return Material(
      color: enabled || loading ? c.record : c.surfaceAlt,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.lg)),
      child: InkWell(
        onTap: enabled ? onPressed : null,
        borderRadius: BorderRadius.circular(Radii.lg),
        child: SizedBox(
          width: 58,
          height: 46,
          child: loading
              ? Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: c.recordText),
                  ),
                )
              : Center(
                  child: Text(
                    '存',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: enabled ? c.recordText : c.textMuted,
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
