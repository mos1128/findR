import type { MemoryCard } from '../types';

/**
 * 备份（.findrpack）的容器与端口定义。
 *
 * 两条硬约束来自《技术设计.md》第七节，改动前先读那一节：
 *   1. **永不包含 API Key 与生物锁设置** —— 导出侧走 settings_public 白名单（见 manifest.ts），
 *      不是「过滤掉看起来像密钥的」，而是「只放白名单里的」，方向反过来才对。
 *   2. **core 不直接依赖任何 crypto / 文件实现** —— RN 侧与 node 测试侧各自注入。
 */

/** 平台实现可能是同步的（node:crypto）也可能是异步的（WebCrypto / react-native-quick-crypto） */
export type MaybePromise<T> = T | Promise<T>;

export interface CryptoPort {
  randomBytes(length: number): MaybePromise<Uint8Array>;
  pbkdf2Sha256(
    passphrase: string,
    salt: Uint8Array,
    iterations: number,
    keyBytes: number,
  ): MaybePromise<Uint8Array>;
  /** 返回 ciphertext ‖ tag(16B)；tag 由实现追加到密文尾 */
  aesGcmEncrypt(
    key: Uint8Array,
    nonce: Uint8Array,
    plaintext: Uint8Array,
  ): MaybePromise<Uint8Array>;
  /** 入参是 ciphertext ‖ tag(16B)；tag 不匹配必须抛错，不允许返回部分明文 */
  aesGcmDecrypt(key: Uint8Array, nonce: Uint8Array, sealed: Uint8Array): MaybePromise<Uint8Array>;
}

/**
 * 媒体文件读写端口。相对路径就是 DB 里存的相对路径（`files/cards/202609/<cardId>/01.webp`），
 * 绝对根目录由平台层拼（见 media/paths.ts）。
 */
export interface MediaStorePort {
  /** 文件不存在返回 null，不抛错：DB 可能引用已被回收、或拍完没保存的路径 */
  read(relPath: string): MaybePromise<Uint8Array | null>;
  write(relPath: string, data: Uint8Array): MaybePromise<void>;
  /** 只判存在。不实现则导入侧退化为 read 一次（结果相同，只是多读一遍文件） */
  exists?(relPath: string): MaybePromise<boolean>;
}

/** ZIP 内的媒体成员索引，导入时用来校验完整性 */
export interface MediaEntryMeta {
  path: string;
  size: number;
  crc32: number;
}

export interface BackupManifest {
  format: 'findrpack';
  formatVersion: number;
  schemaVersion: number;
  exportedAt: string;
  /** 仅用于排查，不参与合并决策 */
  appVersion?: string;
  cards: MemoryCard[];
  categories: BackupCategory[];
  locations: BackupLocation[];
  aliases: BackupAlias[];
  /** 非机密设置（绝不含 Key / 生物锁） */
  settings: Record<string, unknown>;
  media: MediaEntryMeta[];
}

export interface BackupCategory {
  id: string;
  name: string;
  emoji: string | null;
  description: string | null;
  sort: number;
  isPreset: boolean;
}

export interface BackupLocation {
  id: string;
  parentId: string | null;
  name: string;
  sort: number;
}

export interface BackupAlias {
  id: string;
  kind: 'entity' | 'location';
  name: string;
  cardId: string | null;
  locationId: string | null;
}

export interface ExportReport {
  cards: number;
  categories: number;
  locations: number;
  aliases: number;
  mediaTotal: number;
  mediaWritten: number;
  /** DB 里引用了但磁盘上已不存在的媒体（不阻断导出，列出来让人知道） */
  mediaMissing: string[];
  /** 整包字节数（含头与 tag） */
  bytes: number;
}

export interface BackupConflict {
  kind: 'category' | 'location';
  importedId: string;
  localId: string;
  name: string;
}

export interface ImportReport {
  cardsInserted: number;
  cardsUpdated: number;
  /** 本地同 id 更新更新，或本地更新更新（updated_at 新者胜） */
  cardsKeptLocal: number;
  categoriesInserted: number;
  categoriesKeptLocal: number;
  locationsInserted: number;
  locationsKeptLocal: number;
  aliasesInserted: number;
  settingsWritten: number;
  settingsKeptLocal: number;
  mediaWritten: number;
  /** 本地已有同路径媒体（按设计「媒体按相对路径覆盖」，这里只统计覆盖次数） */
  mediaOverwritten: number;
  /** 卡片引用的 category/location 在本地不存在，按名字重映射回本地 id 的次数 */
  remappedCategoryRefs: number;
  remappedLocationRefs: number;
  /** 重映射也失败、只能置空的外键引用次数 */
  droppedRefs: number;
  conflicts: BackupConflict[];
}
