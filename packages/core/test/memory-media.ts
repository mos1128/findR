import type { MediaStorePort } from '../src/backup/types';

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
