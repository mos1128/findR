import { expect, test } from 'vitest';
import { cardBadges, badgeLabel, canReanalyze, cardNeedsAttention } from '../src/cards/badges';
import { makeCard } from './helpers';

const CTX = { visionSupported: true, asrConfigured: true };
const NO_ASR = { visionSupported: true, asrConfigured: false };
const NO_VISION = { visionSupported: false, asrConfigured: true };

test('待转写与解析中互斥，来自生命周期状态', () => {
  expect(cardBadges(makeCard({ id: 'a', status: 'pending_transcript' }))).toEqual([
    'pending-transcript',
  ]);
  expect(cardBadges(makeCard({ id: 'b', status: 'pending' }))).toEqual(['processing']);
  expect(cardBadges(makeCard({ id: 'c', status: 'active' }))).toEqual([]);
  expect(cardBadges(makeCard({ id: 'd', status: 'archived' }))).toEqual([]);
});

test('未配 ASR 时「待转写」的文案改为提示配置', () => {
  expect(badgeLabel('pending-transcript', CTX)).toBe('待转写');
  expect(badgeLabel('pending-transcript', NO_ASR)).toBe('待转写·未配 ASR');
});

test('pending 的文案是「待解析」而不是「解析中」', () => {
  // 与《需求.md》状态表对齐（pending = 待解析）。
  // 没配模型时卡片会一直停在这一步，写成「解析中」会让人以为正在跑、白等。
  expect(badgeLabel('processing', CTX)).toBe('待解析');
});

test('待整理角标独立于其他状态', () => {
  expect(cardBadges(makeCard({ id: 'b', needsOrganize: true }))).toEqual(['needs-organize']);
});

test('未分析角标只看「有图且没成功分析过」', () => {
  expect(cardBadges(makeCard({ id: 'a', images: ['x.webp'], visionAnalyzed: false }))).toContain(
    'unanalyzed',
  );
  expect(
    cardBadges(makeCard({ id: 'b', images: ['x.webp'], visionAnalyzed: true })),
  ).not.toContain('unanalyzed');
  expect(cardBadges(makeCard({ id: 'c', images: null, visionAnalyzed: null }))).not.toContain(
    'unanalyzed',
  );
  // 解析失败但没分析过图：角标必须还在，否则成了一张既无 desc 又无提示的裸卡
  expect(
    cardBadges(
      makeCard({ id: 'd', images: ['x.webp'], visionAnalyzed: false, needsOrganize: true }),
    ),
  ).toEqual(['needs-organize', 'unanalyzed']);
});

test('「用户主动关闭」与「模型不支持」在文案上区分（需求 5.1）', () => {
  expect(badgeLabel('unanalyzed', CTX)).toBe('未分析');
  expect(badgeLabel('unanalyzed', NO_VISION)).toBe('未分析·模型无视觉');
});

test('模型不支持视觉时禁用补分析', () => {
  const card = makeCard({ id: 'a', images: ['x.webp'], visionAnalyzed: false });
  expect(canReanalyze(card, CTX)).toBe(true);
  expect(canReanalyze(card, NO_VISION)).toBe(false);
  expect(canReanalyze(makeCard({ id: 'b', images: null }), CTX)).toBe(false);
  expect(canReanalyze(makeCard({ id: 'c', images: ['x.webp'], visionAnalyzed: true }), CTX)).toBe(
    false,
  );
});

test('重试角标只在仍处于待处理时出现', () => {
  expect(cardBadges(makeCard({ id: 'a', status: 'pending', retryCount: 2 }))).toContain('retrying');
  expect(cardBadges(makeCard({ id: 'b', status: 'active', retryCount: 2 }))).not.toContain(
    'retrying',
  );
});

test('需要用户动手的卡片会被标出来', () => {
  expect(cardNeedsAttention(makeCard({ id: 'a', status: 'pending' }))).toBe(true);
  expect(cardNeedsAttention(makeCard({ id: 'b', needsOrganize: true }))).toBe(true);
  expect(cardNeedsAttention(makeCard({ id: 'c', status: 'active' }))).toBe(false);
});
