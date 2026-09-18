import * as SecureStore from 'expo-secure-store';

export type KeySlot = 'llm' | 'asr';

/** Key 只进 Keystore / Keychain，DB 的 settings 与导出备份都不含它（技术设计四） */
const SECURE_KEYS: Record<KeySlot, string> = {
  llm: 'findr.llm.apiKey',
  asr: 'findr.asr.apiKey',
};

export async function getApiKey(slot: KeySlot): Promise<string | null> {
  try {
    return await SecureStore.getItemAsync(SECURE_KEYS[slot]);
  } catch {
    // 设备不支持安全存储时不应让整个应用起不来
    return null;
  }
}

export async function setApiKey(slot: KeySlot, value: string | null): Promise<void> {
  if (value) await SecureStore.setItemAsync(SECURE_KEYS[slot], value);
  else await SecureStore.deleteItemAsync(SECURE_KEYS[slot]);
}

/** 设置页只显示掩码（需求 3.6） */
export function maskApiKey(key: string | null): string {
  if (!key) return '未配置';
  if (key.length <= 8) return '••••••';
  return `${key.slice(0, 4)}••••${key.slice(-4)}`;
}
