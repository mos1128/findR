/// 卡片角标。
///
/// **每个角标都必须绑一个明确的清除动作**：
/// 没有清除路径的角标只会变成擦不掉的噪音。
library;

import '../types.dart';

enum CardBadge {
  /// 待转写：有音频但还没转成文字。
  pendingTranscript('pending-transcript'),

  /// 待转写 / 转写中 / 待解析 / 解析中：素材已落盘，等队列转写或理解。
  ///
  /// 文案看**配置**而不是看进度：队列是串行的，界面拿不到「这条正在被处理」的信号，
  /// 而用户的心智很简单 —— 没配 ASR 就是「待转写」（等你配），配了就是「转写中」（排队里）。
  /// 队列要跑起来还得有主模型（`buildAdvanceDeps` 缺它就整个拒绝），
  /// 所以只配了 ASR 时仍写「待转写」，并把缺的那一半写进文案，别让人白等。
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
  const BadgeContext({
    required this.visionSupported,
    required this.asrConfigured,
    required this.modelConfigured,
  });

  /// 主模型是否支持图片输入。
  final bool visionSupported;

  /// 是否配置了可用的 ASR，决定「待转写」是提示配置还是提示补文字。
  final bool asrConfigured;

  /// 是否配置了主模型。缺它时解析队列整条都不跑（转写也跟着停），
  /// 文案必须回到「待转写 / 待解析」，不能写成进行中。
  final bool modelConfigured;
}

List<CardBadge> cardBadges(MemoryCard card) {
  final badges = <CardBadge>[];
  // 失败过的卡片只留「重试中」：它的转写/解析已经停了（重试用尽后队列再也不会碰它），
  // 再叠一句「转写中」是自相矛盾。
  final untouched = card.retryCount == 0;
  if (card.status == CardStatus.pendingTranscript && untouched) {
    badges.add(CardBadge.pendingTranscript);
  }
  if (card.status == CardStatus.pending && untouched) badges.add(CardBadge.processing);
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
  CardBadge.pendingTranscript => !ctx.asrConfigured
      ? '待转写·未配 ASR'
      : (ctx.modelConfigured ? '转写中' : '待转写·未配主模型'),
  CardBadge.processing => ctx.modelConfigured ? '解析中' : '待解析',
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
