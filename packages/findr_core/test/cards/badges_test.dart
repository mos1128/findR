/// 卡片角标的判定 —— 逐字对应 `packages/core/test/badges.test.ts`（77 行）。
///
/// 核心不变量：**每个角标都要么来自生命周期状态、要么来自一个可清除的缺陷**，
/// 且「用户主动关闭」与「模型不支持」在文案上必须区分（需求 5.1）。
library;

import 'package:findr_core/findr_core.dart';
import 'package:test/test.dart';

import '../helpers.dart';

const BadgeContext ctx = BadgeContext(visionSupported: true, asrConfigured: true);
const BadgeContext noAsr = BadgeContext(visionSupported: true, asrConfigured: false);
const BadgeContext noVision = BadgeContext(visionSupported: false, asrConfigured: true);

void main() {
  test('待转写与解析中互斥，来自生命周期状态', () {
    expect(cardBadges(makeCard(id: 'a', status: CardStatus.pendingTranscript)), [
      CardBadge.pendingTranscript,
    ]);
    expect(cardBadges(makeCard(id: 'b', status: CardStatus.pending)), [CardBadge.processing]);
    expect(cardBadges(makeCard(id: 'c', status: CardStatus.active)), isEmpty);
    expect(cardBadges(makeCard(id: 'd', status: CardStatus.archived)), isEmpty);
  });

  test('未配 ASR 时「待转写」的文案改为提示配置', () {
    expect(badgeLabel(CardBadge.pendingTranscript, ctx), '待转写');
    expect(badgeLabel(CardBadge.pendingTranscript, noAsr), '待转写·未配 ASR');
  });

  test('pending 的文案是「待解析」而不是「解析中」', () {
    // 与《需求.md》状态表对齐（pending = 待解析）。
    // 没配模型时卡片会一直停在这一步，写成「解析中」会让人以为正在跑、白等。
    expect(badgeLabel(CardBadge.processing, ctx), '待解析');
  });

  test('待整理角标独立于其他状态', () {
    expect(cardBadges(makeCard(id: 'b', needsOrganize: true)), [CardBadge.needsOrganize]);
  });

  test('未分析角标只看「有图且没成功分析过」', () {
    expect(
      cardBadges(makeCard(id: 'a', images: ['x.webp'], visionAnalyzed: false)),
      contains(CardBadge.unanalyzed),
    );
    expect(
      cardBadges(makeCard(id: 'b', images: ['x.webp'], visionAnalyzed: true)),
      isNot(contains(CardBadge.unanalyzed)),
    );
    expect(
      cardBadges(makeCard(id: 'c')),
      isNot(contains(CardBadge.unanalyzed)),
    );
    // 解析失败但没分析过图：角标必须还在，否则成了一张既无 desc 又无提示的裸卡
    expect(
      cardBadges(
        makeCard(id: 'd', images: ['x.webp'], visionAnalyzed: false, needsOrganize: true),
      ),
      [CardBadge.needsOrganize, CardBadge.unanalyzed],
    );
  });

  test('「用户主动关闭」与「模型不支持」在文案上区分（需求 5.1）', () {
    expect(badgeLabel(CardBadge.unanalyzed, ctx), '未分析');
    expect(badgeLabel(CardBadge.unanalyzed, noVision), '未分析·模型无视觉');
  });

  test('模型不支持视觉时禁用补分析', () {
    final card = makeCard(id: 'a', images: ['x.webp'], visionAnalyzed: false);
    expect(canReanalyze(card, ctx), isTrue);
    expect(canReanalyze(card, noVision), isFalse);
    expect(canReanalyze(makeCard(id: 'b'), ctx), isFalse);
    expect(canReanalyze(makeCard(id: 'c', images: ['x.webp'], visionAnalyzed: true), ctx), isFalse);
  });

  test('重试角标只在仍处于待处理时出现', () {
    expect(
      cardBadges(makeCard(id: 'a', status: CardStatus.pending, retryCount: 2)),
      contains(CardBadge.retrying),
    );
    expect(
      cardBadges(makeCard(id: 'b', status: CardStatus.active, retryCount: 2)),
      isNot(contains(CardBadge.retrying)),
    );
  });

  test('需要用户动手的卡片会被标出来', () {
    expect(cardNeedsAttention(makeCard(id: 'a', status: CardStatus.pending)), isTrue);
    expect(cardNeedsAttention(makeCard(id: 'b', needsOrganize: true)), isTrue);
    expect(cardNeedsAttention(makeCard(id: 'c', status: CardStatus.active)), isFalse);
  });
}
