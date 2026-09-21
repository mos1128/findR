import type { MemoryCard } from '../types';

export type CardBadge =
  /** 待转写：有音频但还没转成文字 */
  | 'pending-transcript'
  /**
   * 待解析：素材已落盘，等待（或正在）理解。
   *
   * 文案刻意用「待解析」而不是「解析中」——与《需求.md》状态表的 `pending 待解析` 一致。
   * 理由：没配模型时队列根本不会跑，卡片会无限期停在这一步，说「解析中（进行中）」是误导，
   * 用户会一直等一个不会发生的动作（真机反馈）。
   */
  | 'processing'
  /** 待整理：结构化解析失败，只剩原文与图片 */
  | 'needs-organize'
  /** 未分析：有图但没送过模型做视觉理解 */
  | 'unanalyzed'
  /** 失败待重试 */
  | 'retrying';

export interface BadgeContext {
  /** 主模型是否支持图片输入 */
  visionSupported: boolean;
  /** 是否配置了 ASR，决定「待转写」是提示配置还是提示补文字 */
  asrConfigured: boolean;
}

/** 每个角标都必须绑一个明确的清除动作，见技术设计五与需求 5.1 */
export function cardBadges(card: MemoryCard): CardBadge[] {
  const badges: CardBadge[] = [];
  if (card.status === 'pending_transcript') badges.push('pending-transcript');
  if (card.status === 'pending') badges.push('processing');
  if (card.needsOrganize) badges.push('needs-organize');

  const hasImages = !!card.images && card.images.length > 0;
  if (hasImages && card.visionAnalyzed !== true) badges.push('unanalyzed');

  const stillPending = card.status === 'pending' || card.status === 'pending_transcript';
  if (stillPending && card.retryCount > 0) badges.push('retrying');

  return badges;
}

/**
 * 「用户主动关闭图片分析」与「模型不支持图片」在 UI 上必须区分（需求 5.1）。
 * 前者可随时补分析，后者要引导换模型。
 */
export function badgeLabel(badge: CardBadge, ctx: BadgeContext): string {
  switch (badge) {
    case 'pending-transcript':
      return ctx.asrConfigured ? '待转写' : '待转写·未配 ASR';
    case 'processing':
      return '待解析';
    case 'needs-organize':
      return '待整理';
    case 'unanalyzed':
      return ctx.visionSupported ? '未分析' : '未分析·模型无视觉';
    case 'retrying':
      return '重试中';
  }
}

/** 模型不支持视觉时禁用「补分析图片」，否则用户会反复点一个注定失败的按钮 */
export function canReanalyze(card: MemoryCard, ctx: BadgeContext): boolean {
  return (
    ctx.visionSupported && !!card.images && card.images.length > 0 && card.visionAnalyzed !== true
  );
}

/** 卡片是否还需要用户动手（用来在记忆流里把待办性质的卡排前面或加提示） */
export function cardNeedsAttention(card: MemoryCard): boolean {
  return (
    card.needsOrganize ||
    card.status === 'pending_transcript' ||
    card.status === 'pending'
  );
}
