/// 底部坞里药丸两侧那两颗定形的块。
///
/// 首页录入条和搜索页共用同一套尺寸与形状：中间是药丸，右边是「按下去这件事就结束」
/// 的实心块，左边是一颗方形的副按钮。两页长得一样，用户就不必重新学一遍
/// 「现在按下去会发生什么」。
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// 坞里的方形图标按钮：首页的 `＋`、搜索页的「文字 / 语音」切换。
class DockIconButton extends StatelessWidget {
  const DockIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.active = false,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;

  /// 这颗按钮代表的模式正在生效（`＋` 展开了素材、搜索页处在语音态）。
  final bool active;

  /// 长按才看得到的名字：光看图标猜不出动作时给它。
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final on = onPressed != null;
    final button = Material(
      color: c.surfaceAlt,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.pill),
        side: BorderSide.none,
      ),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(Radii.pill),
        child: SizedBox(
          width: 38,
          height: 38,
          child: Icon(
            icon,
            size: 20,
            color: active ? c.record : (on ? c.textSecondary : c.textMuted),
          ),
        ),
      ),
    );
    final tip = tooltip;
    return tip == null ? button : Tooltip(message: tip, child: button);
  }
}

/// 坞最右边的提交块：首页是「存」，搜索页是「搜」。
///
/// **整屏唯一用强调色的实心块** —— 一屏只有一颗「按下去这件事就结束」的按钮，
/// 它才值得被一眼找到。
class DockCommitButton extends StatelessWidget {
  const DockCommitButton({
    super.key,
    required this.label,
    required this.enabled,
    required this.onPressed,
    this.loading = false,
  });

  final String label;
  final bool enabled;

  /// 正在提交：按钮留在原位转圈，不要整颗消失。
  final bool loading;

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final active = enabled || loading;
    return Material(
      color: active ? c.record : c.surfaceAlt,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.pill),
        side: BorderSide.none,
      ),
      child: InkWell(
        onTap: enabled ? onPressed : null,
        borderRadius: BorderRadius.circular(Radii.pill),
        child: SizedBox(
          width: 44,
          height: 38,
          child: Center(
            child: loading
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: c.recordText,
                    ),
                  )
                : Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
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
