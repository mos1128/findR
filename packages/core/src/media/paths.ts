import type { MemoryCard } from '../types';

/** 媒体布局见技术设计二：DB 只存相对路径，绝对根目录由平台层拼接 */
export function monthDir(date: Date): string {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  return `${y}${m}`;
}

export function cardMediaDir(date: Date, cardId: string): string {
  return `files/cards/${monthDir(date)}/${cardId}`;
}

/** files/cards/<yyyymm>/<cardId>/01.webp —— index 从 0 起，落到文件名是 01 起（顺序即拍摄顺序） */
export function imageRelPath(date: Date, cardId: string, index: number, ext = 'webp'): string {
  return `${cardMediaDir(date, cardId)}/${String(index + 1).padStart(2, '0')}.${ext}`;
}

export function audioRelPath(date: Date, cardId: string, ext = 'm4a'): string {
  return `files/audio/${monthDir(date)}/${cardId}.${ext}`;
}

/** 单卡图片超过该张数时提示确认（需求 5.1 的存储侧软约束，不是硬截断） */
export const MAX_CAPTURE_IMAGES_WARN = 12;

/** 回收某张卡片的全部媒体相对路径 */
export function cardMediaPaths(card: MemoryCard): string[] {
  const paths: string[] = [];
  if (card.images) paths.push(...card.images);
  if (card.audioPath) paths.push(card.audioPath);
  return paths;
}

/** 录音时长下限：低于这个值基本是误触 */
export const MIN_RECORDING_MS = 500;
