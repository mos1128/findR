const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/** 逆向表：字符码 → 6bit 值，非法字符标 -1 */
const LOOKUP = (() => {
  const table = new Int8Array(128).fill(-1);
  for (let i = 0; i < ALPHABET.length; i++) table[ALPHABET.charCodeAt(i)] = i;
  return table;
})();

/**
 * 纯 JS 的 base64 编解码。
 * 刻意不用 Buffer（RN 无此全局）也不用 atob（Hermes 支持不稳），
 * 保证 core 在 node 与设备上是同一套行为。
 */
export function base64ToBytes(input: string): Uint8Array {
  const n = input.length;
  const out = new Uint8Array(Math.floor((n * 3) / 4));
  let outLen = 0;
  let buffer = 0;
  let bits = 0;
  for (let i = 0; i < n; i++) {
    const code = input.charCodeAt(i);
    const value = code < 128 ? LOOKUP[code] : -1;
    if (value < 0) continue; // 跳过换行、`=` 填充等
    buffer = (buffer << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[outLen++] = (buffer >> bits) & 0xff;
    }
  }
  return out.subarray(0, outLen);
}

export function bytesToBase64(bytes: Uint8Array): string {
  let out = '';
  let buffer = 0;
  let bits = 0;
  for (let i = 0; i < bytes.length; i++) {
    buffer = (buffer << 8) | bytes[i];
    bits += 8;
    while (bits >= 6) {
      bits -= 6;
      out += ALPHABET[(buffer >> bits) & 0x3f];
    }
  }
  if (bits > 0) out += ALPHABET[(buffer << (6 - bits)) & 0x3f];
  while (out.length % 4 !== 0) out += '=';
  return out;
}
