import type { CryptoPort } from './types';

/**
 * .findrpack 容器：头部明文 + 分块 AES-256-GCM 密文流。布局见《技术设计.md》第七节。
 *
 *   magic "FINDR"(5B) + format version u16 (=1) + salt(16B) + nonce_base(12B)
 *   └ 密文流：每块明文 ≤256KB，块尾附 16B tag；nonce = nonce_base ‖ chunk_seq(u32 LE)
 *   密钥 = PBKDF2-HMAC-SHA256(passphrase, salt, 600_000 iter, 32B)
 *
 * 分块的意义：GCM 单次能处理的长度有上限，而且一次加密几百 MB 会同时占住明文+密文两份内存。
 * 按 256KB 切，峰值只多一块；每块独立 tag，篡改任何一块都会在那一块解密时就炸。
 *
 * ⚠️ nonce 是 16 字节，不是 GCM 推荐的 12 字节（96 bit）。这是设计文档定死的布局，
 * OpenSSL / Node / WebCrypto 都接受 16 字节（内部会先做一次 GHASH 派生），
 * 但对新实现的 RN crypto provider 要多验一次——见交接文档的待办。
 */

export const MAGIC = 'FINDR';
export const FORMAT_VERSION = 1;
export const SALT_LEN = 16;
export const NONCE_BASE_LEN = 12;
export const NONCE_LEN = NONCE_BASE_LEN + 4;
export const TAG_LEN = 16;
export const KEY_LEN = 32;
export const CHUNK_SIZE = 256 * 1024;
export const PBKDF2_ITERATIONS = 600_000;
export const HEADER_LEN = MAGIC.length + 2 + SALT_LEN + NONCE_BASE_LEN;

export interface PackHeader {
  formatVersion: number;
  salt: Uint8Array;
  nonceBase: Uint8Array;
}

export function encodeHeader(h: PackHeader): Uint8Array {
  const out = new Uint8Array(HEADER_LEN);
  for (let i = 0; i < MAGIC.length; i++) out[i] = MAGIC.charCodeAt(i);
  const view = new DataView(out.buffer);
  view.setUint16(MAGIC.length, h.formatVersion, true);
  out.set(h.salt, MAGIC.length + 2);
  out.set(h.nonceBase, MAGIC.length + 2 + SALT_LEN);
  return out;
}

export function decodeHeader(bytes: Uint8Array): PackHeader {
  if (bytes.length < HEADER_LEN) throw new Error('备份文件过短，不是有效的 .findrpack');
  for (let i = 0; i < MAGIC.length; i++) {
    if (bytes[i] !== MAGIC.charCodeAt(i)) throw new Error('备份文件标识不符，不是 .findrpack 文件');
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const formatVersion = view.getUint16(MAGIC.length, true);
  if (formatVersion !== FORMAT_VERSION) {
    throw new Error(`备份格式版本 ${formatVersion} 不被支持（当前支持 ${FORMAT_VERSION}）`);
  }
  return {
    formatVersion,
    salt: bytes.slice(MAGIC.length + 2, MAGIC.length + 2 + SALT_LEN),
    nonceBase: bytes.slice(MAGIC.length + 2 + SALT_LEN, HEADER_LEN),
  };
}

export async function deriveKey(
  crypto: CryptoPort,
  passphrase: string,
  salt: Uint8Array,
): Promise<Uint8Array> {
  if (!passphrase) throw new Error('备份口令不能为空');
  return await crypto.pbkdf2Sha256(passphrase, salt, PBKDF2_ITERATIONS, KEY_LEN);
}

function chunkNonce(nonceBase: Uint8Array, seq: number): Uint8Array {
  const nonce = new Uint8Array(NONCE_LEN);
  nonce.set(nonceBase, 0);
  new DataView(nonce.buffer).setUint32(NONCE_BASE_LEN, seq, true);
  return nonce;
}

/** 把明文切成 ≤CHUNK_SIZE 的块逐块加密；返回的密文流每块尾部自带 16B tag */
export async function encryptChunks(
  crypto: CryptoPort,
  key: Uint8Array,
  nonceBase: Uint8Array,
  plaintext: Uint8Array,
): Promise<Uint8Array> {
  const parts: Uint8Array[] = [];
  let total = 0;
  let seq = 0;
  for (let off = 0; off < plaintext.length; off += CHUNK_SIZE) {
    const slice = plaintext.subarray(off, Math.min(off + CHUNK_SIZE, plaintext.length));
    const sealed = await crypto.aesGcmEncrypt(key, chunkNonce(nonceBase, seq), slice);
    parts.push(sealed);
    total += sealed.length;
    seq++;
  }
  const out = new Uint8Array(total);
  let p = 0;
  for (const part of parts) {
    out.set(part, p);
    p += part.length;
  }
  return out;
}

/**
 * 分块解密。块边界不写在文件里：除最后一块外每块长度恒定，最后一块按剩余长度倒推，
 * 所以篡改长度会直接导致 tag 校验失败，而不是悄悄产生错位明文。
 */
export async function decryptChunks(
  crypto: CryptoPort,
  key: Uint8Array,
  nonceBase: Uint8Array,
  ciphertext: Uint8Array,
): Promise<Uint8Array> {
  const parts: Uint8Array[] = [];
  let total = 0;
  let off = 0;
  let seq = 0;
  while (off < ciphertext.length) {
    const remaining = ciphertext.length - off;
    if (remaining < TAG_LEN) throw new Error('备份文件被截断：密文尾部不完整');
    const take = Math.min(remaining, CHUNK_SIZE + TAG_LEN);
    const pt = await crypto.aesGcmDecrypt(
      key,
      chunkNonce(nonceBase, seq),
      ciphertext.subarray(off, off + take),
    );
    parts.push(pt);
    total += pt.length;
    off += take;
    seq++;
  }
  const out = new Uint8Array(total);
  let p = 0;
  for (const part of parts) {
    out.set(part, p);
    p += part.length;
  }
  return out;
}

/** 明文 → 完整 .findrpack 字节（头 + 密文）。salt / nonce_base 由 crypto 端口提供随机源 */
export async function seal(
  crypto: CryptoPort,
  passphrase: string,
  plaintext: Uint8Array,
): Promise<Uint8Array> {
  const salt = await crypto.randomBytes(SALT_LEN);
  const nonceBase = await crypto.randomBytes(NONCE_BASE_LEN);
  if (salt.length !== SALT_LEN || nonceBase.length !== NONCE_BASE_LEN) {
    throw new Error('crypto 端口返回的随机字节长度不符');
  }
  const key = await deriveKey(crypto, passphrase, salt);
  const ciphertext = await encryptChunks(crypto, key, nonceBase, plaintext);
  const header = encodeHeader({ formatVersion: FORMAT_VERSION, salt, nonceBase });
  const out = new Uint8Array(header.length + ciphertext.length);
  out.set(header, 0);
  out.set(ciphertext, header.length);
  return out;
}

/** .findrpack 字节 → 明文。口令错 / 文件损坏 / 被篡改都会在这里抛错 */
export async function open(
  crypto: CryptoPort,
  passphrase: string,
  bytes: Uint8Array,
): Promise<Uint8Array> {
  const header = decodeHeader(bytes);
  const key = await deriveKey(crypto, passphrase, header.salt);
  return await decryptChunks(crypto, key, header.nonceBase, bytes.subarray(HEADER_LEN));
}
