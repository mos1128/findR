import { ImageManipulator, SaveFormat } from 'expo-image-manipulator';
import { File } from 'expo-file-system';

import { writeMediaFile } from '@/platform/media';

/** 入库压缩参数：长边 ≤1600px、WebP quality 0.8（技术设计二） */
export const MAX_LONG_EDGE = 1600;
export const WEBP_QUALITY = 0.8;

export interface SourceImage {
  uri: string;
  width: number;
  height: number;
}

/** 压到 WebP 并落进媒体目录。返回相对路径（DB 只存相对路径） */
export async function saveImageAsWebp(source: SourceImage, rel: string): Promise<void> {
  const context = ImageManipulator.manipulate(source.uri);
  if (Math.max(source.width, source.height) > MAX_LONG_EDGE) {
    // 只给长边，另一边交给它按比例算，避免自己算错
    if (source.width >= source.height) context.resize({ width: MAX_LONG_EDGE });
    else context.resize({ height: MAX_LONG_EDGE });
  }
  const rendered = await context.renderAsync();
  const saved = await rendered.saveAsync({ format: SaveFormat.WEBP, compress: WEBP_QUALITY });
  // 临时文件在缓存目录里，读出来写进文档目录；写文件必须早于插行
  const bytes = await new File(saved.uri).bytes();
  writeMediaFile(rel, bytes);
}

/** 录音文件从缓存搬进媒体目录 */
export async function saveAudioFile(tempUri: string, rel: string): Promise<void> {
  const bytes = await new File(tempUri).bytes();
  writeMediaFile(rel, bytes);
}
