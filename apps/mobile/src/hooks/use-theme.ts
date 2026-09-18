import { Colors } from '@/constants/theme';
import { useColorScheme } from '@/hooks/use-color-scheme';

/** 颜色方案可能是 null（系统未指定），一律落到浅色，避免 Colors[null] 取到 undefined */
export function useTheme() {
  const scheme = useColorScheme();
  return Colors[scheme === 'dark' ? 'dark' : 'light'];
}

export type Theme = ReturnType<typeof useTheme>;
