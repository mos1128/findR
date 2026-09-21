/// Findr 的设计令牌 —— **这一版是重新设计的**（Flutter 迁移的附赠好处：
/// 不必继承 RN 的版式，见 `Flutter迁移交接.md` §1）。
///
/// 设计原则（承接需求六，但换一套做法）：
///
/// - **「查」与「记」是两条链路，必须强区分**。「查」用中性冷灰（克制、不抢注意力），
///   「记」用唯一的品牌蓝（这是整屏唯一允许出现的强调色块）。
///   这个区分不是审美问题 —— 需求六明确说合并会让「记」被误判成「查」而**丢数据**。
/// - **卡片上唯一的强调色是角标与分类标签**，其余一律中性。卡片的层次靠
///   「浅色底 + 发丝边 + 极轻的阴影」而不是靠重色块，因为一屏可能有几十张。
/// - 明暗两套**同一套语义名**，组件只认语义、不认具体色值。
///
/// 用 [ThemeExtension] 挂进 `ThemeData`：组件通过 `FindrTokens.of(context)` 取，
/// 于是「换主题」这件事被收在一个地方（也顺带让 widget 测试能用 `tester.platformDispatcher`
/// 之外的方式注入，不必去改全局）。
library;

import 'package:flutter/material.dart';

/// 一套语义色。字段名即用途，**不要在组件里写死十六进制**。
@immutable
final class FindrColors extends ThemeExtension<FindrColors> {
  const FindrColors({
    required this.background,
    required this.surface,
    required this.surfaceAlt,
    required this.surfaceSunken,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.textSecondary,
    required this.textMuted,
    required this.search,
    required this.searchSurface,
    required this.record,
    required this.recordText,
    required this.badgePending,
    required this.badgePendingBg,
    required this.badgeConfirm,
    required this.badgeConfirmBg,
    required this.badgeOrganize,
    required this.badgeOrganizeBg,
    required this.badgeUnanalyzed,
    required this.badgeUnanalyzedBg,
    required this.danger,
    required this.success,
    required this.shadow,
  });

  /// 整屏底色。
  final Color background;

  /// 卡片、面板。
  final Color surface;

  /// 次级面（提示条、占位块、内嵌输入）。
  final Color surfaceAlt;

  /// 再深一级（用于在 surfaceAlt 上再挖一层，比如输入框放在提示条里）。
  final Color surfaceSunken;

  final Color border;

  /// 需要更清楚的轮廓时（聚焦框、选中的 chip）。
  final Color borderStrong;

  final Color text;
  final Color textSecondary;
  final Color textMuted;

  /// 「查」的语义色：搜索图标、检索结果标题。
  final Color search;

  /// 顶栏底色 —— 与 [background] 拉开一点点，让「查」有自己的面。
  final Color searchSurface;

  /// 「记」的语义色。**整屏唯一的强调色**。
  final Color record;

  /// 压在 [record] 上的前景色（按钮文字 / 图标）。
  final Color recordText;

  final Color badgePending;
  final Color badgePendingBg;
  final Color badgeConfirm;
  final Color badgeConfirmBg;
  final Color badgeOrganize;
  final Color badgeOrganizeBg;
  final Color badgeUnanalyzed;
  final Color badgeUnanalyzedBg;

  final Color danger;
  final Color success;

  /// 卡片阴影。暗色下几乎看不见，所以给一个可调的值而不是写死黑色。
  final Color shadow;

  static const FindrColors light = FindrColors(
    background: Color(0xFFF4F6F8),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFEDF0F4),
    surfaceSunken: Color(0xFFE4E8EE),
    border: Color(0xFFE3E7ED),
    borderStrong: Color(0xFFC3CBD6),
    text: Color(0xFF16181B),
    textSecondary: Color(0xFF5A6169),
    textMuted: Color(0xFF98A0A8),
    search: Color(0xFF55637A),
    searchSurface: Color(0xFFFBFCFD),
    record: Color(0xFF1D7BF0),
    recordText: Color(0xFFFFFFFF),
    badgePending: Color(0xFF6B7280),
    badgePendingBg: Color(0xFFEDF0F4),
    badgeConfirm: Color(0xFF9A6400),
    badgeConfirmBg: Color(0xFFFDF3E0),
    badgeOrganize: Color(0xFFB3261E),
    badgeOrganizeBg: Color(0xFFFDF0EF),
    badgeUnanalyzed: Color(0xFF4B5563),
    badgeUnanalyzedBg: Color(0xFFEDEFF2),
    danger: Color(0xFFB3261E),
    success: Color(0xFF1D7A34),
    shadow: Color(0x14000000),
  );

  static const FindrColors dark = FindrColors(
    background: Color(0xFF0E1013),
    surface: Color(0xFF181B1F),
    surfaceAlt: Color(0xFF212529),
    surfaceSunken: Color(0xFF2A2F35),
    border: Color(0xFF2B3037),
    borderStrong: Color(0xFF454C55),
    text: Color(0xFFF1F3F5),
    textSecondary: Color(0xFFA8AEB6),
    textMuted: Color(0xFF757C85),
    search: Color(0xFFC4CAD3),
    searchSurface: Color(0xFF15181C),
    record: Color(0xFF4C9BFF),
    recordText: Color(0xFF07131F),
    badgePending: Color(0xFFB7BDC7),
    badgePendingBg: Color(0xFF24282D),
    badgeConfirm: Color(0xFFE0B25A),
    badgeConfirmBg: Color(0xFF2E2618),
    badgeOrganize: Color(0xFFF08C86),
    badgeOrganizeBg: Color(0xFF2F1D1C),
    badgeUnanalyzed: Color(0xFFB7BDC7),
    badgeUnanalyzedBg: Color(0xFF24282D),
    danger: Color(0xFFF08C86),
    success: Color(0xFF4FBE6B),
    shadow: Color(0x33000000),
  );

  @override
  FindrColors copyWith({
    Color? background,
    Color? surface,
    Color? surfaceAlt,
    Color? surfaceSunken,
    Color? border,
    Color? borderStrong,
    Color? text,
    Color? textSecondary,
    Color? textMuted,
    Color? search,
    Color? searchSurface,
    Color? record,
    Color? recordText,
    Color? badgePending,
    Color? badgePendingBg,
    Color? badgeConfirm,
    Color? badgeConfirmBg,
    Color? badgeOrganize,
    Color? badgeOrganizeBg,
    Color? badgeUnanalyzed,
    Color? badgeUnanalyzedBg,
    Color? danger,
    Color? success,
    Color? shadow,
  }) => FindrColors(
    background: background ?? this.background,
    surface: surface ?? this.surface,
    surfaceAlt: surfaceAlt ?? this.surfaceAlt,
    surfaceSunken: surfaceSunken ?? this.surfaceSunken,
    border: border ?? this.border,
    borderStrong: borderStrong ?? this.borderStrong,
    text: text ?? this.text,
    textSecondary: textSecondary ?? this.textSecondary,
    textMuted: textMuted ?? this.textMuted,
    search: search ?? this.search,
    searchSurface: searchSurface ?? this.searchSurface,
    record: record ?? this.record,
    recordText: recordText ?? this.recordText,
    badgePending: badgePending ?? this.badgePending,
    badgePendingBg: badgePendingBg ?? this.badgePendingBg,
    badgeConfirm: badgeConfirm ?? this.badgeConfirm,
    badgeConfirmBg: badgeConfirmBg ?? this.badgeConfirmBg,
    badgeOrganize: badgeOrganize ?? this.badgeOrganize,
    badgeOrganizeBg: badgeOrganizeBg ?? this.badgeOrganizeBg,
    badgeUnanalyzed: badgeUnanalyzed ?? this.badgeUnanalyzed,
    badgeUnanalyzedBg: badgeUnanalyzedBg ?? this.badgeUnanalyzedBg,
    danger: danger ?? this.danger,
    success: success ?? this.success,
    shadow: shadow ?? this.shadow,
  );

  @override
  FindrColors lerp(covariant FindrColors? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return FindrColors(
      background: mix(background, other.background),
      surface: mix(surface, other.surface),
      surfaceAlt: mix(surfaceAlt, other.surfaceAlt),
      surfaceSunken: mix(surfaceSunken, other.surfaceSunken),
      border: mix(border, other.border),
      borderStrong: mix(borderStrong, other.borderStrong),
      text: mix(text, other.text),
      textSecondary: mix(textSecondary, other.textSecondary),
      textMuted: mix(textMuted, other.textMuted),
      search: mix(search, other.search),
      searchSurface: mix(searchSurface, other.searchSurface),
      record: mix(record, other.record),
      recordText: mix(recordText, other.recordText),
      badgePending: mix(badgePending, other.badgePending),
      badgePendingBg: mix(badgePendingBg, other.badgePendingBg),
      badgeConfirm: mix(badgeConfirm, other.badgeConfirm),
      badgeConfirmBg: mix(badgeConfirmBg, other.badgeConfirmBg),
      badgeOrganize: mix(badgeOrganize, other.badgeOrganize),
      badgeOrganizeBg: mix(badgeOrganizeBg, other.badgeOrganizeBg),
      badgeUnanalyzed: mix(badgeUnanalyzed, other.badgeUnanalyzed),
      badgeUnanalyzedBg: mix(badgeUnanalyzedBg, other.badgeUnanalyzedBg),
      danger: mix(danger, other.danger),
      success: mix(success, other.success),
      shadow: mix(shadow, other.shadow),
    );
  }

  /// 组件里取色的唯一入口。**找不到就抛** —— 那说明 `ThemeData` 没装上扩展，
  /// 与其悄悄回退到一套写死的浅色（暗色模式下会变成看不见的深底深字），不如当场说清楚。
  static FindrColors of(BuildContext context) {
    final tokens = Theme.of(context).extension<FindrColors>();
    if (tokens == null) {
      throw StateError('FindrColors 未挂进 ThemeData —— 请用 buildFindrTheme() 建主题');
    }
    return tokens;
  }
}

/// 间距。沿用 RN 那套倍率（2 / 4 / 8 / 16 / 24 / 32），因为它已经够用且没人需要重学。
abstract final class Spacing {
  static const double half = 2;
  static const double one = 4;
  static const double two = 8;
  static const double three = 12;
  static const double four = 16;
  static const double five = 24;
  static const double six = 32;
}

/// 圆角。
///
/// ⚠️ **类名不能叫 `Radius`** —— Flutter 的 `dart:ui` 里已经有一个 `Radius`，
/// 两边同时 `import` 就会把 `Radius.circular` 解析到我们这套令牌上，
/// 于是所有 `BorderRadius.circular(Radius.md)` 一起报 `undefined_method`。
/// 这不是风格问题，是硬冲突。
abstract final class Radii {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 22;
  static const double pill = 999;
}

/// 内容最大宽度。
///
/// RN 那条 800 的限制在手机上没有作用，但**桌面端（V2/V3）必须留着** ——
/// 否则窗口一拉宽，卡片会被拉成一行超长的字，读起来非常难受。
const double maxContentWidth = 800;

/// 构建主题。
///
/// 刻意**只挂自己这套令牌**，不去覆写一堆 Material 组件的主题：
/// 覆写越多，将来升 Flutter 时被改名的 API 就越多（`CardTheme` → `CardThemeData` 那类）。
/// 需要定制的组件都在 `ui/kit.dart` 里自己画。
ThemeData buildFindrTheme(Brightness brightness) {
  final colors = brightness == Brightness.dark ? FindrColors.dark : FindrColors.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: colors.record,
    brightness: brightness,
  ).copyWith(
    surface: colors.surface,
    onSurface: colors.text,
    primary: colors.record,
    onPrimary: colors.recordText,
    error: colors.danger,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: colors.background,
    // 输入法弹出的那层「候选词条」颜色跟着走，免得暗色下刺眼
    canvasColor: colors.surface,
    splashFactory: InkSparkle.splashFactory,
    extensions: <ThemeExtension<dynamic>>[colors],
  );
}
