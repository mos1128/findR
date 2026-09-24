/// 基础组件。
///
/// 设计上只做三件事，其余交给 `theme/tokens.dart`：
///
/// 1. **组件只认语义令牌**（`FindrColors.of(context)`），不认具体色值 ⇒ 明暗主题自动成立；
/// 2. **能不用 Material 主题就不覆写** —— 覆写越多，升级 Flutter 时踩到改名 API 的机会越多；
/// 3. **凡是「一屏会出现很多次」的组件（卡片、角标）一律不做阴影动画**，
///    几十个 `InkWell` 一起涟漪在低端机上会掉帧。
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// 页面外壳：把内容限制在 [maxContentWidth] 内并居中。
///
/// 手机上看不出区别，桌面上就是「不至于拉成一行超长的字」的保障。
class ScreenBody extends StatelessWidget {
  const ScreenBody({
    super.key,
    required this.slivers,
    this.padding = const EdgeInsets.fromLTRB(
      Spacing.four,
      Spacing.three,
      Spacing.four,
      Spacing.six,
    ),
    this.controller,
  });

  final List<Widget> slivers;
  final EdgeInsets padding;
  final ScrollController? controller;

  /// 便捷构造：整页就是一根可滚动的列。**注意上下要各留一份 padding**，
  /// 否则内容会被上下的固定条（顶栏 / 录入条）压住。
  factory ScreenBody.column({
    Key? key,
    required List<Widget> children,
    EdgeInsets padding = const EdgeInsets.fromLTRB(
      Spacing.four,
      Spacing.three,
      Spacing.four,
      Spacing.six,
    ),
    ScrollController? controller,
    double gap = Spacing.three,
  }) => ScreenBody(
    key: key,
    padding: padding,
    controller: controller,
    slivers: <Widget>[
      SliverPadding(
        padding: padding,
        sliver: SliverList.separated(
          itemCount: children.length,
          separatorBuilder: (_, _) => SizedBox(height: gap),
          itemBuilder: (_, i) => children[i],
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: maxContentWidth),
      child: CustomScrollView(
        controller: controller,
        // 打字时点列表不该收键盘乱跳
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: slivers,
      ),
    ),
  );
}

/// 一块面板（设置页里的一节、卡片详情的分区）。
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.title,
    this.hint,
    this.padding = const EdgeInsets.all(Spacing.four),
    this.gap = Spacing.three,
  });

  final Widget child;
  final String? title;
  final String? hint;
  final EdgeInsets padding;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (title != null) ...<Widget>[
            SectionTitle(title!, hint: hint),
            SizedBox(height: gap),
          ],
          child,
        ],
      ),
    );
  }
}

/// 小节标题 + 右侧灰色小字提示。
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.hint, this.trailing});

  final String title;
  final String? hint;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
              color: c.text,
            ),
          ),
        ),
        if (hint != null && hint!.isNotEmpty)
          Text(hint!, style: TextStyle(fontSize: 11.5, color: c.textMuted)),
        ?trailing,
      ],
    );
  }
}

enum FindrButtonVariant { primary, secondary, danger, ghost }

/// 按钮。`primary` 用「记」的强调色 —— 整屏只有它是实心亮色。
class FindrButton extends StatelessWidget {
  const FindrButton({
    super.key,
    required this.title,
    this.onPressed,
    this.variant = FindrButtonVariant.primary,
    this.compact = false,
    this.loading = false,
    this.icon,
    this.expand = true,
  });

  final String title;
  final VoidCallback? onPressed;
  final FindrButtonVariant variant;
  final bool compact;
  final bool loading;
  final IconData? icon;

  /// 是否撑满一行。`ghost` 按钮在标题行里用 `false`。
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final (Color bg, Color fg, Color? border) = switch (variant) {
      FindrButtonVariant.primary => (c.record, c.recordText, null),
      FindrButtonVariant.secondary => (c.surfaceSunken, c.text, null),
      FindrButtonVariant.danger => (c.danger, Colors.white, null),
      FindrButtonVariant.ghost => (Colors.transparent, c.record, null),
    };
    // 文字与图标一起上色，别只改一个
    final style = TextStyle(
      fontSize: compact ? 13 : 14.5,
      fontWeight: FontWeight.w600,
      color: fg,
      letterSpacing: 0.1,
    );
    final child = loading
        ? SizedBox(
            width: compact ? 14 : 18,
            height: compact ? 14 : 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: fg),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: compact ? 15 : 18, color: fg),
                const SizedBox(width: Spacing.two),
              ],
              Flexible(
                child: Text(title, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ],
          );

    final button = TextButton(
      onPressed: loading ? null : onPressed,
      style: TextButton.styleFrom(
        backgroundColor: bg,
        foregroundColor: fg,
        elevation: variant == FindrButtonVariant.primary && !loading && onPressed != null ? 2 : 0,
        shadowColor: c.record.withValues(alpha: 0.3),
        disabledBackgroundColor: bg.withValues(alpha: 0.4),
        disabledForegroundColor: fg.withValues(alpha: 0.5),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? Spacing.three : Spacing.four,
          vertical: compact ? 8 : 12,
        ),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          side: border == null ? BorderSide.none : BorderSide(color: border),
        ),
      ),
      child: child,
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// 分类筛选 / 可点标签。
class FindrChip extends StatelessWidget {
  const FindrChip({
    super.key,
    required this.label,
    this.active = false,
    this.onPressed,
    this.dense = false,
    this.canvas = false,
  });

  final String label;
  final bool active;
  final VoidCallback? onPressed;
  final bool dense;

  /// 是否位于页面大底色（如记忆流顶栏筛选区）上；在底色上未激活态使用纯白以提升对比度。
  final bool canvas;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = active
        ? (isDark ? Colors.white : c.text)
        : (canvas
            ? (isDark ? c.surfaceAlt : Colors.white)
            : c.surfaceAlt);
    final fg = active
        ? (isDark ? const Color(0xFF121212) : Colors.white)
        : c.textSecondary;

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(Radii.pill),
      elevation: 0,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(Radii.pill),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: dense ? Spacing.three + 2 : Spacing.four,
            vertical: dense ? 6 : 8,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: dense ? 12.5 : 13.5,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: fg,
              letterSpacing: -0.1,
            ),
          ),
        ),
      ),
    );
  }
}

/// 角标色板。
enum BadgeTone { neutral, confirm, organize, unanalyzed, accent }

class FindrBadge extends StatelessWidget {
  const FindrBadge({super.key, required this.label, this.tone = BadgeTone.neutral});

  final String label;
  final BadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final (Color bg, Color fg) = switch (tone) {
      BadgeTone.neutral => (c.surfaceAlt, c.textSecondary),
      BadgeTone.confirm => (c.badgeConfirmBg, c.badgeConfirm),
      BadgeTone.organize => (c.badgeOrganizeBg, c.badgeOrganize),
      BadgeTone.unanalyzed => (c.badgeUnanalyzedBg, c.badgeUnanalyzed),
      BadgeTone.accent => (c.record.withValues(alpha: 0.1), c.record),
    };
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Radii.xs + 2),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: fg,
          letterSpacing: 0.1,
        ),
      ),
    );
  }
}

/// 提示条的语调。
enum NoticeTone {
  /// 中性说明（走的是哪条检索路、正在组织答案…）。
  info,

  /// 需要用户留意但不致命（未配模型、未配 ASR、无网）。
  warn,

  /// 出错了。
  danger,

  /// 成功。
  success,
}

/// 提示条 —— 全 App 唯一的「说一句话」组件。
class Notice extends StatelessWidget {
  const Notice({
    super.key,
    required this.text,
    this.tone = NoticeTone.info,
    this.title,
    this.action,
    this.icon,
    this.surface = false,
  });

  final String text;
  final NoticeTone tone;
  final String? title;
  final Widget? action;
  final IconData? icon;
  final bool surface;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final (Color fg, Color defaultBg, IconData defaultIcon) = switch (tone) {
      NoticeTone.info => (c.textSecondary, c.surfaceAlt, Icons.info_outline_rounded),
      NoticeTone.warn => (c.badgeConfirm, c.badgeConfirmBg.withValues(alpha: 0.5), Icons.lightbulb_outline_rounded),
      NoticeTone.danger => (c.danger, c.badgeOrganizeBg.withValues(alpha: 0.5), Icons.error_outline_rounded),
      NoticeTone.success => (c.success, c.surfaceAlt, Icons.check_circle_outline_rounded),
    };
    final bg = surface ? c.surface : defaultBg;
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(surface ? Radii.lg : Radii.md),
      ),
      padding: const EdgeInsets.symmetric(horizontal: Spacing.four, vertical: Spacing.three),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon ?? defaultIcon, size: 16, color: fg),
          ),
          const SizedBox(width: Spacing.three),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (title != null) ...<Widget>[
                  Text(
                    title!,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: fg),
                  ),
                  const SizedBox(height: Spacing.one),
                ],
                Text(text, style: TextStyle(fontSize: 12.5, height: 1.45, color: fg)),
                if (action != null) ...<Widget>[
                  const SizedBox(height: Spacing.two),
                  Align(alignment: Alignment.centerLeft, child: action),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 空态。
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, this.hint, this.icon});

  final String title;
  final String? hint;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.six + 8, horizontal: Spacing.four),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: c.surface,
                  shape: BoxShape.circle,
                ),
                child: Center(child: Icon(icon, size: 26, color: c.textMuted)),
              ),
              const SizedBox(height: Spacing.three),
            ],
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: c.text,
                letterSpacing: -0.2,
              ),
            ),
            if (hint != null) ...<Widget>[
              const SizedBox(height: Spacing.two),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: Text(
                  hint!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, height: 1.5, color: c.textMuted),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 带标签的输入框。
class FindrField extends StatelessWidget {
  const FindrField({
    super.key,
    required this.label,
    this.controller,
    this.hint,
    this.note,
    this.placeholder,
    this.obscure = false,
    this.multiline = false,
    this.keyboardType,
    this.onChanged,
    this.minLines,
    this.maxLines,
    this.focusNode,
    this.trailing,
    this.suffixIcon,
    this.enabled = true,
  });

  final String label;
  final TextEditingController? controller;
  final String? hint;

  /// 字段下方的小灰字（比 [hint] 更长的说明）。
  final String? note;
  final String? placeholder;
  final bool obscure;
  final bool multiline;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final int? minLines;
  final int? maxLines;
  final FocusNode? focusNode;
  final Widget? trailing;
  final Widget? suffixIcon;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.textSecondary),
              ),
            ),
            ?trailing,
          ],
        ),
        const SizedBox(height: Spacing.two),
        TextField(
          controller: controller,
          focusNode: focusNode,
          obscureText: obscure,
          enabled: enabled,
          keyboardType: multiline ? TextInputType.multiline : keyboardType,
          minLines: multiline ? (minLines ?? 3) : null,
          maxLines: multiline ? (maxLines ?? 8) : 1,
          onChanged: onChanged,
          style: TextStyle(fontSize: 14.5, color: c.text),
          decoration: InputDecoration(
            isDense: true,
            hintText: placeholder,
            hintStyle: TextStyle(fontSize: 14, color: c.textMuted),
            suffixIcon: suffixIcon,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: Spacing.four,
              vertical: Spacing.three,
            ),
            filled: true,
            fillColor: c.surfaceAlt,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Radii.md),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Radii.md),
              borderSide: BorderSide.none,
            ),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Radii.md),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Radii.md),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        if (hint != null) ...<Widget>[
          const SizedBox(height: Spacing.one),
          Text(hint!, style: TextStyle(fontSize: 11.5, color: c.textMuted)),
        ],
        if (note != null) ...<Widget>[
          const SizedBox(height: Spacing.two),
          Text(note!, style: TextStyle(fontSize: 11.5, height: 1.4, color: c.textMuted)),
        ],
      ],
    );
  }
}

/// 设置页里的一行。
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.right,
    this.onTap,
    this.onLongPress,
    this.leading,
  });

  final String title;
  final String? subtitle;
  final Widget? right;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(Radii.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.three, horizontal: Spacing.two),
        child: Row(
          children: <Widget>[
            if (leading != null) ...<Widget>[leading!, const SizedBox(width: Spacing.three)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: c.text),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, height: 1.35, color: c.textSecondary),
                    ),
                  ],
                ],
              ),
            ),
            if (right != null) ...<Widget>[const SizedBox(width: Spacing.two), right!],
          ],
        ),
      ),
    );
  }
}

/// 一条与面板同宽的分隔线。
class FindrDivider extends StatelessWidget {
  const FindrDivider({super.key, this.indent = 0});

  final double indent;

  @override
  Widget build(BuildContext context) => Container(
    height: 1,
    margin: EdgeInsets.only(left: indent),
    color: FindrColors.of(context).border,
  );
}

/// 页面顶栏。左「返回」右「动作」，标题居中偏左。
///
/// 用 `PreferredSizeWidget` 而不是 `AppBar`：`AppBar` 的默认主题带一堆我们不要的东西
/// （大标题滚动折叠、表面着色），要把它扳回我们要的样子反而比自绘更长。
class FindrTopBar extends StatelessWidget implements PreferredSizeWidget {
  const FindrTopBar({super.key, required this.title, this.actions, this.onBack});

  final String title;
  final List<Widget>? actions;
  final VoidCallback? onBack;

  @override
  Size get preferredSize => const Size.fromHeight(52);

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    return Container(
      color: c.searchSurface,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 52,
          child: Row(
            children: <Widget>[
              const SizedBox(width: Spacing.one),
              IconButton(
                onPressed: onBack ?? () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back_rounded, size: 22),
                color: c.textSecondary,
                tooltip: '返回',
              ),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w600, color: c.text),
                ),
              ),
              ...?actions,
              const SizedBox(width: Spacing.two),
            ],
          ),
        ),
      ),
    );
  }
}

/// 屏幕宽度（给布局判断用，顺便让测试能覆盖「窄屏」这一档）。
double screenWidth(BuildContext context) => MediaQuery.sizeOf(context).width;
