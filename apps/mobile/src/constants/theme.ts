import { Platform } from 'react-native';

/**
 * Findr 配色：只有「查」和「记」两条主链路需要强视觉区分（需求六），
 * 其余保持中性，让角标和分类标签成为卡片上唯一的强调色。
 */
export const Colors = {
  light: {
    background: '#F7F8FA',
    surface: '#FFFFFF',
    surfaceAlt: '#EEF0F4',
    border: '#E2E5EA',
    text: '#151719',
    textSecondary: '#5B6169',
    textMuted: '#9AA0A6',
    /** 「查」：顶部搜索与分类筛选 */
    search: '#4B5A6B',
    searchSurface: '#FFFFFF',
    /** 「记」：底部一体化输入条 */
    record: '#208AEF',
    recordText: '#FFFFFF',
    /** 角标 */
    badgePending: '#6B7280',
    badgePendingBg: '#EEF0F4',
    badgeConfirm: '#9A6400',
    badgeConfirmBg: '#FDF3E0',
    badgeOrganize: '#B3261E',
    badgeOrganizeBg: '#FDF0EF',
    badgeUnanalyzed: '#4B5563',
    badgeUnanalyzedBg: '#EDEFF2',
    /** 结构类型 */
    item: '#1F6FEB',
    todo: '#C2610A',
    procedure: '#1D7A34',
    danger: '#B3261E',
    success: '#1D7A34',
  },
  dark: {
    background: '#0F1113',
    surface: '#191B1E',
    surfaceAlt: '#212428',
    border: '#2C3036',
    text: '#F2F3F5',
    textSecondary: '#A9AEB6',
    textMuted: '#767C85',
    search: '#C3C9D2',
    searchSurface: '#191B1E',
    record: '#3B9BFF',
    recordText: '#08131F',
    badgePending: '#B7BDC7',
    badgePendingBg: '#24282D',
    badgeConfirm: '#E0B25A',
    badgeConfirmBg: '#2E2618',
    badgeOrganize: '#F08C86',
    badgeOrganizeBg: '#2F1D1C',
    badgeUnanalyzed: '#B7BDC7',
    badgeUnanalyzedBg: '#24282D',
    item: '#5C9DFF',
    todo: '#E09B4A',
    procedure: '#4FBE6B',
    danger: '#F08C86',
    success: '#4FBE6B',
  },
} as const;

export type ThemeColor = keyof typeof Colors.light & keyof typeof Colors.dark;

export const Fonts = Platform.select({
  ios: { mono: 'ui-monospace' },
  default: { mono: 'monospace' },
});

export const Spacing = {
  half: 2,
  one: 4,
  two: 8,
  three: 16,
  four: 24,
  five: 32,
  six: 64,
} as const;

export const Radius = {
  sm: 8,
  md: 12,
  lg: 16,
  pill: 999,
} as const;

export const MaxContentWidth = 800;

/** 与「场景分析 四」的结构类型一一对应，分类标签与卡片强调色都用它 */
export const structureAccent: Record<'item' | 'todo' | 'procedure', ThemeColor> = {
  item: 'item',
  todo: 'todo',
  procedure: 'procedure',
};

export const structureLabel: Record<'item' | 'todo' | 'procedure', string> = {
  item: '物品',
  todo: '待办',
  procedure: '流程',
};
