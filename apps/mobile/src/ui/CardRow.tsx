import { Image } from 'expo-image';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import {
  badgeLabel,
  cardBadges,
  type BadgeContext,
  type CardBadge,
  type MemoryCard,
  type SourceKind,
} from '@findr/core';

import { Radius, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { Badge, type BadgeTone } from './kit';
import { mediaUri } from '@/platform/media';

const BADGE_TONES: Record<CardBadge, BadgeTone> = {
  'pending-transcript': 'neutral',
  processing: 'neutral',
  'needs-organize': 'organize',
  unanalyzed: 'unanalyzed',
  retrying: 'organize',
};

/**
 * 输入来源的图标与短标签。
 *
 * 列表以前看不出「这条是长按说话记的，还是打字记的」（真机反馈）：
 * 卡片上只有标题与角标，而角标一旦清掉（转写完成 / 解析完成）就再也分不出来，
 * 详情页的原文与播放器又得点进去才看得到。
 * 所以列表里两处都带来源：缩略图位给没图的卡当占位符，副标题第一段给一行白纸黑字。
 */
const SOURCE_ICON: Record<SourceKind, string> = { voice: '🎙️', text: '⌨️', photo: '📷' };
const SOURCE_LABEL: Record<SourceKind, string> = { voice: '语音', text: '文字', photo: '照片' };

/** 老行 / 异常行的兜底：source 缺失时按「文字」处理，别让卡片渲染出一块空白 */
function sourceOf(card: MemoryCard): SourceKind {
  return card.source === 'voice' || card.source === 'photo' ? card.source : 'text';
}

/**
 * 卡片主标题的兜底顺序：实体名 → desc → 原文。
 *
 * 全空时按来源给占位（「（语音）」/「（照片）」/「（文字）」），而不是笼统一句「（待整理）」——
 * 「待整理」是 `needs-organize` 角标的专用词（`需求.md` 3.4），拿它当空标题会让用户
 * 以为卡片解析失败了（真机反馈：两张语音卡都写着「（待整理）」，与角标「待转写」互相打架）。
 */
function titleOf(card: MemoryCard): string {
  if (card.entity) return card.entity;
  if (card.desc) return card.desc.slice(0, 30);
  if (card.transcript) return card.transcript.slice(0, 30);
  return `（${SOURCE_LABEL[sourceOf(card)]}）`;
}

function subtitleOf(
  card: MemoryCard,
  categoryName: string | null,
  categoryEmoji: string | null,
): string {
  const kind = sourceOf(card);
  const parts: string[] = [];
  // 来源排最前：一眼分清语音 / 文字 / 照片，不必点进详情
  parts.push(`${SOURCE_ICON[kind]} ${SOURCE_LABEL[kind]}`);
  // 分类的 Emoji 从缩略图挪到这里 —— 缩略图现在归「来源」，分类仍要看得见
  if (categoryName) parts.push(`${categoryEmoji ?? ''}${categoryName}`.trim());
  if (card.pathNames) parts.push(card.pathNames);
  if (card.desc && card.entity) parts.push(card.desc);
  else if (card.transcript && (card.entity || card.desc)) parts.push(card.transcript);
  return parts.join(' · ');
}

export function CardRow({
  card,
  ctx,
  categoryName,
  categoryEmoji,
  highlight,
  note,
  onPress,
}: {
  card: MemoryCard;
  ctx: BadgeContext;
  categoryName: string | null;
  /** 分类 Emoji，拼在副标题的分类名前面（缩略图位改用来显示输入来源） */
  categoryEmoji?: string | null;
  /** L2 答案依据的卡片，在结果里加一圈强调色（需求六「答案卡片置顶高亮」） */
  highlight?: boolean;
  /**
   * 「这条为什么出现在这里」—— 只有建议型结果（advise）会传。
   * 建议结果里的卡片不是字面命中，是模型挑出来的；不给理由，用户无从判断要不要信它。
   */
  note?: string;
  onPress?: () => void;
}) {
  const theme = useTheme();
  const badges = cardBadges(card);
  const cover = card.images && card.images.length > 0 ? card.images[0] : null;

  return (
    <Pressable
      onPress={onPress}
      style={({ pressed }) => [
        styles.row,
        {
          backgroundColor: theme.surface,
          borderColor: highlight ? theme.record : theme.border,
          borderWidth: highlight ? 1.5 : StyleSheet.hairlineWidth,
          opacity: pressed ? 0.75 : 1,
        },
      ]}>
      {cover ? (
        <Image source={{ uri: mediaUri(cover) }} style={styles.cover} contentFit="cover" />
      ) : (
        /*
          没有封面图时的占位块。
          以前是「surfaceAlt 底色（无边框）+ 一个「·」」，深色模式下就是一个没有轮廓的黑方块里
          点了一个点，看着像控件坏了（真机反馈）。现在给边框 + 来源图标：
          既是有轮廓的占位符，又顺手回答了「这条是语音还是打字记的」。
        */
        <View
          style={[
            styles.cover,
            styles.coverFallback,
            { backgroundColor: theme.surfaceAlt, borderColor: theme.border },
          ]}>
          <Text style={styles.coverIcon}>{SOURCE_ICON[sourceOf(card)]}</Text>
        </View>
      )}

      <View style={styles.body}>
        <View style={styles.titleRow}>
          <Text style={[styles.title, { color: theme.text }]} numberOfLines={1}>
            {titleOf(card)}
          </Text>
          {card.status === 'archived' ? <Badge label="已归档" tone="neutral" /> : null}
        </View>

        <Text style={[styles.subtitle, { color: theme.textSecondary }]} numberOfLines={2}>
          {subtitleOf(card, categoryName, categoryEmoji ?? null)}
        </Text>

        {badges.length > 0 ? (
          <View style={styles.badges}>
            {badges.map((b) => (
              <Badge key={b} label={badgeLabel(b, ctx)} tone={BADGE_TONES[b]} />
            ))}
          </View>
        ) : null}

        {/* P1 的补问入口：非阻塞，最多一句（需求 5.1） */}
        {card.ask ? (
          <Text style={[styles.ask, { color: theme.badgeConfirm }]} numberOfLines={2}>
            想确认：{card.ask}
          </Text>
        ) : null}

        {/* 建议型结果的入选理由 —— 放在最后，不抢标题与副标题的位置 */}
        {note ? (
          <Text style={[styles.note, { color: theme.record }]} numberOfLines={2}>
            {note}
          </Text>
        ) : null}
      </View>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    gap: Spacing.three,
    padding: Spacing.three,
    borderRadius: Radius.md,
    borderWidth: StyleSheet.hairlineWidth,
  },
  cover: { width: 64, height: 64, borderRadius: Radius.sm },
  /** 占位块要有轮廓：只靠底色在深色模式下几乎与卡片同色，会被看成「坏掉的黑框」 */
  coverFallback: {
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: StyleSheet.hairlineWidth,
  },
  coverIcon: { fontSize: 26 },
  body: { flex: 1, gap: 4 },
  titleRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  title: { fontSize: 15, fontWeight: '600', flexShrink: 1 },
  subtitle: { fontSize: 12, lineHeight: 17 },
  badges: { flexDirection: 'row', flexWrap: 'wrap', gap: 4, marginTop: 2 },
  ask: { fontSize: 12, marginTop: 2 },
  note: { fontSize: 12, lineHeight: 17, marginTop: 2 },
});
