import type { PropsWithChildren, ReactNode } from 'react';
import {
  ActivityIndicator,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
  type TextInputProps,
} from 'react-native';

import { Radius, Spacing } from '@/constants/theme';
import { useTheme, type Theme } from '@/hooks/use-theme';

export function useKit() {
  const theme = useTheme();
  return { theme, styles: makeStyles(theme) };
}

export function Screen({ children, scroll = true }: PropsWithChildren<{ scroll?: boolean }>) {
  const { theme, styles } = useKit();
  if (!scroll) return <View style={[styles.screen, { backgroundColor: theme.background }]}>{children}</View>;
  return (
    <ScrollView
      style={[styles.screen, { backgroundColor: theme.background }]}
      contentContainerStyle={styles.screenContent}
      keyboardShouldPersistTaps="handled">
      {children}
    </ScrollView>
  );
}

export function Panel({ children, style }: PropsWithChildren<{ style?: object }>) {
  const { theme, styles } = useKit();
  return (
    <View style={[styles.panel, { backgroundColor: theme.surface, borderColor: theme.border }, style]}>
      {children}
    </View>
  );
}

export function SectionTitle({ children, hint }: { children: ReactNode; hint?: string }) {
  const { theme, styles } = useKit();
  return (
    <View style={styles.sectionTitle}>
      <Text style={[styles.sectionTitleText, { color: theme.textSecondary }]}>{children}</Text>
      {hint ? <Text style={[styles.sectionHint, { color: theme.textMuted }]}>{hint}</Text> : null}
    </View>
  );
}

type ButtonVariant = 'primary' | 'record' | 'secondary' | 'danger' | 'ghost';

export function Button({
  title,
  onPress,
  variant = 'primary',
  disabled,
  loading,
  compact,
}: {
  title: string;
  onPress: () => void;
  variant?: ButtonVariant;
  disabled?: boolean;
  loading?: boolean;
  compact?: boolean;
}) {
  const { theme, styles } = useKit();
  const background: Record<ButtonVariant, string> = {
    primary: theme.record,
    record: theme.record,
    secondary: theme.surfaceAlt,
    danger: theme.danger,
    ghost: 'transparent',
  };
  const color: Record<ButtonVariant, string> = {
    primary: theme.recordText,
    record: theme.recordText,
    secondary: theme.text,
    danger: '#ffffff',
    ghost: theme.record,
  };
  const off = disabled || loading;
  return (
    <Pressable
      onPress={onPress}
      disabled={off}
      style={({ pressed }) => [
        styles.button,
        compact && styles.buttonCompact,
        { backgroundColor: background[variant], opacity: off ? 0.45 : pressed ? 0.8 : 1 },
      ]}>
      {loading ? (
        <ActivityIndicator color={color[variant]} size="small" />
      ) : (
        <Text style={[styles.buttonText, compact && styles.buttonTextCompact, { color: color[variant] }]}>
          {title}
        </Text>
      )}
    </Pressable>
  );
}

export function Chip({
  label,
  active,
  onPress,
}: {
  label: string;
  active?: boolean;
  onPress?: () => void;
}) {
  const { theme, styles } = useKit();
  return (
    <Pressable
      onPress={onPress}
      style={({ pressed }) => [
        styles.chip,
        {
          backgroundColor: active ? theme.search : theme.surfaceAlt,
          borderColor: active ? theme.search : theme.border,
          opacity: pressed ? 0.8 : 1,
        },
      ]}>
      <Text style={[styles.chipText, { color: active ? '#ffffff' : theme.textSecondary }]}>
        {label}
      </Text>
    </Pressable>
  );
}

export type BadgeTone = 'neutral' | 'confirm' | 'organize' | 'unanalyzed' | 'accent';

export function Badge({ label, tone = 'neutral' }: { label: string; tone?: BadgeTone }) {
  const { theme, styles } = useKit();
  const map: Record<BadgeTone, { fg: string; bg: string }> = {
    neutral: { fg: theme.badgePending, bg: theme.badgePendingBg },
    confirm: { fg: theme.badgeConfirm, bg: theme.badgeConfirmBg },
    organize: { fg: theme.badgeOrganize, bg: theme.badgeOrganizeBg },
    unanalyzed: { fg: theme.badgeUnanalyzed, bg: theme.badgeUnanalyzedBg },
    accent: { fg: '#ffffff', bg: theme.record },
  };
  const { fg, bg } = map[tone];
  return (
    <View style={[styles.badge, { backgroundColor: bg }]}>
      <Text style={[styles.badgeText, { color: fg }]}>{label}</Text>
    </View>
  );
}

export function Field({
  label,
  hint,
  ...input
}: TextInputProps & { label: string; hint?: string }) {
  const { theme, styles } = useKit();
  return (
    <View style={styles.field}>
      <Text style={[styles.fieldLabel, { color: theme.textSecondary }]}>{label}</Text>
      <TextInput
        placeholderTextColor={theme.textMuted}
        {...input}
        style={[
          styles.input,
          input.multiline && styles.inputMultiline,
          { color: theme.text, borderColor: theme.border, backgroundColor: theme.surfaceAlt },
          input.style,
        ]}
      />
      {hint ? <Text style={[styles.fieldHint, { color: theme.textMuted }]}>{hint}</Text> : null}
    </View>
  );
}

export function ListRow({
  title,
  subtitle,
  right,
  onPress,
  onLongPress,
}: {
  title: string;
  subtitle?: string | null;
  right?: ReactNode;
  onPress?: () => void;
  onLongPress?: () => void;
}) {
  const { theme, styles } = useKit();
  return (
    <Pressable
      onPress={onPress}
      onLongPress={onLongPress}
      style={({ pressed }) => [styles.listRow, { opacity: pressed && onPress ? 0.7 : 1 }]}>
      <View style={styles.listRowBody}>
        <Text style={[styles.listRowTitle, { color: theme.text }]} numberOfLines={1}>
          {title}
        </Text>
        {subtitle ? (
          <Text style={[styles.listRowSubtitle, { color: theme.textSecondary }]} numberOfLines={2}>
            {subtitle}
          </Text>
        ) : null}
      </View>
      {right}
    </Pressable>
  );
}

export function EmptyState({ title, hint }: { title: string; hint?: string }) {
  const { theme, styles } = useKit();
  return (
    <View style={styles.empty}>
      <Text style={[styles.emptyTitle, { color: theme.textSecondary }]}>{title}</Text>
      {hint ? <Text style={[styles.emptyHint, { color: theme.textMuted }]}>{hint}</Text> : null}
    </View>
  );
}

export function Divider() {
  const { theme } = useKit();
  return <View style={{ height: StyleSheet.hairlineWidth, backgroundColor: theme.border }} />;
}

const makeStyles = (theme: Theme) =>
  StyleSheet.create({
    screen: { flex: 1 },
    screenContent: { padding: Spacing.three, gap: Spacing.three, paddingBottom: Spacing.six },
    panel: { borderRadius: Radius.md, borderWidth: StyleSheet.hairlineWidth, padding: Spacing.three, gap: Spacing.two },
    sectionTitle: { flexDirection: 'row', alignItems: 'baseline', justifyContent: 'space-between' },
    sectionTitleText: { fontSize: 13, fontWeight: '600', letterSpacing: 0.3 },
    sectionHint: { fontSize: 11 },
    button: {
      borderRadius: Radius.md,
      paddingVertical: 13,
      paddingHorizontal: Spacing.three,
      alignItems: 'center',
      justifyContent: 'center',
    },
    buttonCompact: { paddingVertical: 8, paddingHorizontal: Spacing.two },
    buttonText: { fontSize: 15, fontWeight: '600' },
    buttonTextCompact: { fontSize: 13 },
    chip: {
      borderRadius: Radius.pill,
      borderWidth: StyleSheet.hairlineWidth,
      paddingHorizontal: 12,
      paddingVertical: 6,
    },
    chipText: { fontSize: 13 },
    badge: { borderRadius: Radius.sm, paddingHorizontal: 6, paddingVertical: 2 },
    badgeText: { fontSize: 11, fontWeight: '600' },
    field: { gap: 6 },
    fieldLabel: { fontSize: 13, fontWeight: '500' },
    fieldHint: { fontSize: 11, lineHeight: 15 },
    input: {
      borderWidth: StyleSheet.hairlineWidth,
      borderRadius: Radius.sm,
      paddingHorizontal: 10,
      paddingVertical: 9,
      fontSize: 14,
    },
    inputMultiline: { minHeight: 84, textAlignVertical: 'top' },
    listRow: {
      flexDirection: 'row',
      alignItems: 'center',
      gap: Spacing.two,
      paddingVertical: 10,
    },
    listRowBody: { flex: 1, gap: 2 },
    listRowTitle: { fontSize: 15, fontWeight: '500' },
    listRowSubtitle: { fontSize: 12, lineHeight: 16 },
    empty: { alignItems: 'center', paddingVertical: Spacing.six, gap: 6 },
    emptyTitle: { fontSize: 15, fontWeight: '500' },
    emptyHint: { fontSize: 12, textAlign: 'center', paddingHorizontal: Spacing.four },
    muted: { color: theme.textMuted },
  });
