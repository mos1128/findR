import { Directory, File, Paths } from 'expo-file-system';
import type { MediaIO } from '@findr/core';

/** 媒体相对路径（如 files/cards/202603/<id>/01.webp）→ 文档目录下的绝对 File */
function absFile(rel: string): File {
  return new File(Paths.document, ...rel.split('/').filter(Boolean));
}

function parentDir(rel: string): Directory | null {
  const parts = rel.split('/').filter(Boolean);
  parts.pop();
  if (parts.length === 0) return null;
  return new Directory(Paths.document, ...parts);
}

function mimeFromExtension(ext: string): string {
  switch (ext.toLowerCase().replace(/^\./, '')) {
    case 'webp':
      return 'image/webp';
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'm4a':
      return 'audio/m4a';
    case 'wav':
      return 'audio/wav';
    default:
      return 'application/octet-stream';
  }
}

function fileNameOf(rel: string): string {
  return rel.split('/').filter(Boolean).pop() ?? 'file';
}

/** 写入媒体文件，自动补建父目录。先写文件再插行靠它保证原子性 */
export function writeMediaFile(rel: string, content: Uint8Array | string): void {
  const dir = parentDir(rel);
  if (dir && !dir.exists) dir.create({ intermediates: true });
  const file = absFile(rel);
  if (!file.exists) file.create();
  file.write(content);
}

export function mediaExists(rel: string): boolean {
  return absFile(rel).exists;
}

export function mediaUri(rel: string): string {
  return absFile(rel).uri;
}

/**
 * core 的 MediaIO 在设备端的实现。
 * audioPart 刻意返回 { uri, name, type }：RN 的 FormData 只认这种结构来发文件，
 * 且会读 name 作为上传文件名（core 那边传的第三参数在 RN 上会被忽略）。
 */
export const deviceMediaIO: MediaIO = {
  async imageData(rel: string) {
    const file = absFile(rel);
    if (!file.exists) throw new Error(`图片文件不存在：${rel}`);
    return { base64: await file.base64(), mime: mimeFromExtension(file.extension) };
  },

  async audioPart(rel: string, mime: string) {
    const file = absFile(rel);
    if (!file.exists) throw new Error(`音频文件不存在：${rel}`);
    return { uri: file.uri, name: fileNameOf(rel), type: mime };
  },

  fileUri(rel: string): string {
    return absFile(rel).uri;
  },

  async removeCardMedia(relPaths: string[]) {
    for (const rel of relPaths) {
      try {
        const file = absFile(rel);
        if (file.exists) file.delete();
      } catch {
        // 单个文件删不掉不该阻塞其余回收
      }
    }
  },
};
