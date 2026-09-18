import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';

import { RuntimeProvider } from '@/platform/runtime';

export default function RootLayout() {
  return (
    <RuntimeProvider>
      <Stack screenOptions={{ headerTitleAlign: 'center' }}>
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
