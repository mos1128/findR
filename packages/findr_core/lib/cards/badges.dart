/// 卡片角标 —— 逐字对应 `packages/core/src/cards/badges.ts`（77 行）。
///
/// **每个角标都必须绑一个明确的清除动作**（技术设计五与需求 5.1）：
/// 没有清除路径的角标只会变成擦不掉的噪音。
library;

import '../types.dart';

enum CardBadge {
  /// 待转写：有音频但还没转成文字。
  pendingTranscript('pending-transcript'),

  /// 待解析：素材已落盘，等待（或正在）理解。
  ///
  /// 文案刻意用「待解析」而不是「解析中」—— 与《需求.md》状态表的 `pending 待解析` 一致。
  /// 理由：没配模型时队列根本不会跑，卡片会无限期停在这一步，说「解析中（进行中）」是误导，
  /// 用户会一直等一个不会发生的动作（真机反馈）。
  processing('processing'),

  /// 待整理：结构化解析失败，只剩原文与图片。
  needsOrganize('needs-organize'),

  /// 未分析：有图但没送过模型做视觉理解。
  unanalyzed('unanalyzed'),

  /// 失败待重试。
  retrying('retrying');

  const CardBadge(this.wire);

  /// 界面用的标识串（样式表按它取色/取文案）。
  final String wire;
}

/// 角标文案要用的上下文。
final class BadgeContext {
  const BadgeContext({required this.visionSupported, required this.asrConfigured});

  /// 主模型是否支持图片输入。
  final bool visionSupported;

  /// 是否配置了 ASR，决定「待转写」是提示配置还是提示补文字。
  final bool asrConfigured;
}

List<CardBadge> cardBadges(MemoryCard card) {
  final badges = <CardBadge>[];
  if (card.status == CardStatus.pendingTranscript) badges.add(CardBadge.pendingTranscript);
  if (card.status == CardStatus.pending) badges.add(CardBadge.processing);
  if (card.needsOrganize) badges.add(CardBadge.needsOrganize);

  final hasImages = card.images != null && card.images!.isNotEmpty;
  if (hasImages && card.visionAnalyzed != true) badges.add(CardBadge.unanalyzed);

  final stillPending =
      card.status == CardStatus.pending || card.status == CardStatus.pendingTranscript;
  if (stillPending && card.retryCount > 0) badges.add(CardBadge.retrying);

  return badges;
}

/// 「用户主动关闭图片分析」与「模型不支持图片」在 UI 上必须区分（需求 5.1）。
/// 前者可随时补分析，后者要引导换模型。
String badgeLabel(CardBadge badge, BadgeContext ctx) => switch (badge) {
  CardBadge.pendingTranscript => ctx.asrConfigured ? '待转写' : '待转写·未配 ASR',
  CardBadge.processing => '待解析',
  CardBadge.needsOrganize => '待整理',
  CardBadge.unanalyzed => ctx.visionSupported ? '未分析' : '未分析·模型无视觉',
  CardBadge.retrying => '重试中',
};

/// 模型不支持视觉时禁用「补分析图片」，否则用户会反复点一个注定失败的按钮。
bool canReanalyze(MemoryCard card, BadgeContext ctx) =>
    ctx.visionSupported &&
    card.images != null &&
    card.images!.isNotEmpty &&
    card.visionAnalyzed != true;

/// 卡片是否还需要用户动手（用来在记忆流里把待办性质的卡排前面或加提示）。
bool cardNeedsAttention(MemoryCard card) =>
    card.needsOrganize ||
    card.status == CardStatus.pendingTranscript ||
    card.status == CardStatus.pending;
