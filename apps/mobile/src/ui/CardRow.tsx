import { Image } from 'expo-image';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { badgeLabel, cardBadges, type BadgeContext, type CardBadge, type MemoryCard } from '@findr/core';

import { Radius, Spacing, structureLabel } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { Badge, type BadgeTone } from './kit';
import { mediaUri } from '@/platform/media';

const BADGE_TONES: Record<CardBadge, BadgeTone> = {
  'pending-transcript': 'neutral',
  processing: 'neutral',
  'needs-confirm': 'confirm',
  'needs-organize': 'organize',
  unanalyzed: 'unanalyzed',
  retrying: 'organize',
};

/** 卡片主标题的兜底顺序：实体名 → desc → 原文 */
function titleOf(card: MemoryCard): string {
  if (card.entity) return card.entity;
  if (card.desc) return card.desc.slice(0, 30);
  if (card.transcript) return card.transcript.slice(0, 30);
  return '（待整理）';
}

function subtitleOf(card: MemoryCard, categoryName: string | null): string {
  const parts: string[] = [];
  if (categoryName) parts.push(categoryName);
  if (card.pathNames) parts.push(card.pathNames);
  if (card.desc && card.entity) parts.push(card.desc);
  else if (card.transcript && (card.entity || card.desc)) parts.push(card.transcript);
  return parts.join(' · ');
}

export function CardRow({
  card,
  ctx,
  categoryName,
  onPress,
}: {
  card: MemoryCard;
  ctx: BadgeContext;
  categoryName: string | null;
  onPress?: () => void;
}) {
  const theme = useTheme();
  const badges = cardBadges(card);
  const cover = card.images && card.images.length > 0 ? card.images[0] : null;
  const accent = card.structureType ? theme[card.structureType] : theme.textMuted;

  return (
    <Pressable
      onPress={onPress}
      style={({ pressed }) => [
        styles.row,
        { backgroundColor: theme.surface, borderColor: theme.border, opacity: pressed ? 0.75 : 1 },
      ]}>
      {cover ? (
        <Image source={{ uri: mediaUri(cover) }} style={styles.cover} contentFit="cover" />
      ) : (
        <View style={[styles.cover, styles.coverFallback, { backgroundColor: theme.surfaceAlt }]}>
          <Text style={{ color: accent, fontSize: 18 }}>
            {card.structureType ? structureLabel[card.structureType].slice(0, 1) : '·'}
          </Text>
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
          {subtitleOf(card, categoryName)}
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
  coverFallback: { alignItems: 'center', justifyContent: 'center' },
  body: { flex: 1, gap: 4 },
  titleRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  title: { fontSize: 15, fontWeight: '600', flexShrink: 1 },
  subtitle: { fontSize: 12, lineHeight: 17 },
  badges: { flexDirection: 'row', flexWrap: 'wrap', gap: 4, marginTop: 2 },
  ask: { fontSize: 12, marginTop: 2 },
});
