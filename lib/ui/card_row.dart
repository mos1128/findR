/// 记忆流里的一张卡片。
///
/// **角标逻辑全在 core 的 `cards/badges.dart` 里**，这里只负责画。
/// 「哪些角标、文案是什么、能不能补分析」一个都不在界面里判断 ——
/// 那套规则是需求 5.1 / 3.4 的口径，必须与别处共用一份。
library;

import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'kit.dart';
import 'media_view.dart';

/// 输入来源的图标与短标签。
///
/// 列表以前看不出「这条是长按说话记的，还是打字记的」（真机反馈）：
/// 角标一旦清掉（转写完成 / 解析完成）就再也分不出来。
/// 所以缩略图位给没图的卡当占位符，副标题第一段再给一行白纸黑字。
const Map<SourceKind, String> sourceIcon = <SourceKind, String>{
  SourceKind.voice: '🎙️',
  SourceKind.text: '⌨️',
  SourceKind.photo: '📷',
};

const Map<SourceKind, String> sourceLabel = <SourceKind, String>{
  SourceKind.voice: '语音',
  SourceKind.text: '文字',
  SourceKind.photo: '照片',
};

/// 卡片主标题的兜底顺序：实体名 → desc → 原文。
///
/// 全空时按来源给占位（「（语音）」/「（照片）」/「（文字）」），
/// **而不是**笼统一句「（待整理）」——「待整理」是 `needs-organize` 角标的专用词，
/// 拿它当空标题会让用户以为解析失败了（真机反馈：两张语音卡都写「（待整理）」，
/// 与角标「待转写」互相打架）。
String cardTitleOf(MemoryCard card) {
  final entity = card.entity;
  if (entity != null && entity.isNotEmpty) return entity;
  final desc = card.desc;
  if (desc != null && desc.isNotEmpty) return _clip(desc, 30);
  final transcript = card.transcript;
  if (transcript != null && transcript.isNotEmpty) return _clip(transcript, 30);
  return '（${sourceLabel[card.source] ?? '文字'}）';
}

String _clip(String s, int n) => s.length <= n ? s : s.substring(0, n);

/// 副标题：`来源 · 分类 · 位置 · 摘要`。
String cardSubtitleOf(MemoryCard card, String? categoryName, String? categoryEmoji) {
  final parts = <String>[];
  // 来源如果没在左侧封面展示，在副标题开头保留
  parts.add('${sourceIcon[card.source] ?? '⌨️'} ${sourceLabel[card.source] ?? '文字'}');
  if (categoryName != null && categoryName.isNotEmpty) {
    parts.add('$categoryEmoji$categoryName'.trim());
  }
  // 如果位置已经在专门的药丸条里画了，副标题就不重复拼 pathNames，保持信息干练
  final desc = card.desc;
  if (desc != null && desc.isNotEmpty && card.entity != null && card.entity!.isNotEmpty) {
    parts.add(desc);
  } else {
    final transcript = card.transcript;
    if (transcript != null &&
        transcript.isNotEmpty &&
        (card.entity != null || (desc != null && desc.isNotEmpty))) {
      final title = cardTitleOf(card);
      if (transcript != title && !title.startsWith(transcript) && !transcript.startsWith(title)) {
        parts.add(transcript);
      }
    }
  }
  return parts.join(' · ');
}

/// 角标 → 色板。
BadgeTone toneOfBadge(CardBadge badge) => switch (badge) {
  CardBadge.pendingTranscript => BadgeTone.neutral,
  CardBadge.processing => BadgeTone.neutral,
  CardBadge.needsOrganize => BadgeTone.organize,
  CardBadge.unanalyzed => BadgeTone.unanalyzed,
  CardBadge.retrying => BadgeTone.organize,
};

/// 记忆流里的一行。
class CardRow extends StatelessWidget {
  const CardRow({
    super.key,
    required this.card,
    required this.ctx,
    this.categoryName,
    this.categoryEmoji,
    this.highlight = false,
    this.note,
    this.onTap,
    this.onLongPress,
  });

  final MemoryCard card;

  /// 角标文案要用它（是否支持视觉、是否配了 ASR）。
  final BadgeContext ctx;

  final String? categoryName;
  final String? categoryEmoji;

  /// L2 答案依据的卡片，在结果里加一圈强调色。
  final bool highlight;

  /// 「这条为什么出现在这里」—— 只有建议型结果（advise）会传。
  ///
  /// 建议结果里的卡片不是字面命中，是模型挑出来的；**不给理由，用户无从判断要不要信它**。
  final String? note;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final badges = cardBadges(card);
    final images = card.images;
    final hasImages = images != null && images.isNotEmpty;
    final cover = hasImages ? images.first : null;
    final path = card.pathNames;

    return Material(
      color: c.surface,
      borderRadius: BorderRadius.circular(Radii.lg),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(Radii.lg),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.lg),
            border: highlight ? Border.all(color: c.record, width: 1.5) : null,
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: highlight ? c.record.withValues(alpha: 0.12) : c.shadow,
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
              BoxShadow(
                color: c.shadow.withValues(alpha: 0.03),
                blurRadius: 2,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          padding: const EdgeInsets.all(Spacing.four),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            cardTitleOf(card),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                              color: c.text,
                              height: 1.3,
                            ),
                          ),
                        ),
                        if (card.status == CardStatus.archived) ...<Widget>[
                          const SizedBox(width: Spacing.two),
                          const FindrBadge(label: '已归档'),
                        ],
                      ],
                    ),
                    const SizedBox(height: Spacing.two),
                    Text(
                      cardSubtitleOf(card, categoryName, categoryEmoji),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, height: 1.45, color: c.textSecondary),
                    ),
                    if (path != null && path.isNotEmpty) ...<Widget>[
                      const SizedBox(height: Spacing.two),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: c.record.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(Radii.xs + 2),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(Icons.place_rounded, size: 12, color: c.record),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Text(
                                path,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: c.record,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (badges.isNotEmpty) ...<Widget>[
                      const SizedBox(height: Spacing.two),
                      Wrap(
                        spacing: Spacing.one + 1,
                        runSpacing: Spacing.one + 1,
                        children: <Widget>[
                          for (final b in badges)
                            FindrBadge(label: badgeLabel(b, ctx), tone: toneOfBadge(b)),
                        ],
                      ),
                    ],
                    if (card.ask != null && card.ask!.isNotEmpty) ...<Widget>[
                      const SizedBox(height: Spacing.two),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: c.badgeConfirmBg,
                          borderRadius: BorderRadius.circular(Radii.sm),
                        ),
                        child: Row(
                          children: <Widget>[
                            Icon(Icons.help_outline_rounded, size: 14, color: c.badgeConfirm),
                            const SizedBox(width: Spacing.one),
                            Expanded(
                              child: Text(
                                '想确认：${card.ask}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.35,
                                  color: c.badgeConfirm,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    // 建议结果的入选理由 —— 放最后，不抢标题与副标题的位置
                    if (note != null && note!.isNotEmpty) ...<Widget>[
                      const SizedBox(height: Spacing.two),
                      Text(
                        note!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, height: 1.35, color: c.record),
                      ),
                    ],
                  ],
                ),
              ),
              if (hasImages) ...<Widget>[
                const SizedBox(width: Spacing.three),
                Stack(
                  children: <Widget>[
                    MediaThumb(
                      relPath: cover,
                      size: 72,
                      fallbackIcon: '📷',
                    ),
                    if (images.length > 1)
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(Radii.pill),
                          ),
                          child: Text(
                            '${images.length}张',
                            style: const TextStyle(
                              fontSize: 9.5,
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
