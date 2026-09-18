import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';

import { useTheme } from '@/hooks/use-theme';
import { RuntimeProvider } from '@/platform/runtime';

export default function RootLayout() {
  const theme = useTheme();

  return (
    <RuntimeProvider>
      {/*
        导航头部必须显式跟随 App 主题：不写的话它用 React Navigation 的默认浅色主题，
        深色模式下顶部会留一条白栏；而 <StatusBar style="auto" /> 在深色模式下给的是
        浅色图标 ⇒ 白底白图标，状态栏的时间和电量看不见。
      */}
      <Stack
        screenOptions={{
          headerTitleAlign: 'center',
          headerStyle: { backgroundColor: theme.background },
          headerTintColor: theme.text,
          headerTitleStyle: { color: theme.text },
          headerShadowVisible: false,
          contentStyle: { backgroundColor: theme.background },
        }}>
        <Stack.Screen name="index" options={{ title: 'Findr' }} />
        <Stack.Screen name="capture" options={{ title: '记一笔', presentation: 'modal' }} />
        <Stack.Screen name="card/[id]" options={{ title: '卡片' }} />
        <Stack.Screen name="settings/index" options={{ title: '设置' }} />
        <Stack.Screen name="settings/provider" options={{ title: '模型配置' }} />
        <Stack.Screen name="settings/locations" options={{ title: '位置树' }} />
        <Stack.Screen name="settings/categories" options={{ title: '分类' }} />
        <Stack.Screen name="selfcheck" options={{ title: '自检' }} />
      </Stack>
      <StatusBar style="auto" />
    </RuntimeProvider>
  );
}
