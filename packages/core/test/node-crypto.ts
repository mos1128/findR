import { createCipheriv, createDecipheriv, pbkdf2Sync, randomBytes } from 'node:crypto';
import type { CryptoPort, MediaStorePort } from '../src/backup/types';

/**
 * node 侧注入实现。设备端要换成 react-native-quick-crypto（或 WebCrypto），
 * 接口一致，这正是 core 不直接依赖 crypto 的意义。
 *
 * 注意 aes-256-gcm 用的是 **16 字节 nonce**（技术设计七定的布局），
 * node/OpenSSL 接受任意长度，所以这里看不出问题；换 RN provider 时要重验这一条。
 */
export function nodeCrypto(): CryptoPort {
  return {
    randomBytes: (length) => new Uint8Array(randomBytes(length)),
    pbkdf2Sha256: (passphrase, salt, iterations, keyBytes) =>
      new Uint8Array(pbkdf2Sync(passphrase, Buffer.from(salt), iterations, keyBytes, 'sha256')),
    aesGcmEncrypt: (key, nonce, plaintext) => {
      const cipher = createCipheriv('aes-256-gcm', Buffer.from(key), Buffer.from(nonce));
      const body = Buffer.concat([cipher.update(Buffer.from(plaintext)), cipher.final()]);
      return new Uint8Array(Buffer.concat([body, cipher.getAuthTag()]));
    },
    aesGcmDecrypt: (key, nonce, sealed) => {
      const decipher = createDecipheriv('aes-256-gcm', Buffer.from(key), Buffer.from(nonce));
      decipher.setAuthTag(Buffer.from(sealed.subarray(sealed.length - 16)));
      const body = sealed.subarray(0, sealed.length - 16);
      return new Uint8Array(Buffer.concat([decipher.update(Buffer.from(body)), decipher.final()]));
    },
  };
}

export interface MemoryMedia extends MediaStorePort {
  files: Map<string, Uint8Array>;
}

/** 内存媒体库：让备份测试完全不碰磁盘 */
export function memoryMedia(initial: Record<string, Uint8Array> = {}): MemoryMedia {
  const files = new Map<string, Uint8Array>(Object.entries(initial));
  return {
    files,
    read: (relPath) => files.get(relPath) ?? null,
    write: (relPath, data) => {
      files.set(relPath, data);
    },
    exists: (relPath) => files.has(relPath),
  };
}
