import * as Crypto from 'expo-crypto';
import {
  audioRelPath,
  createDraft,
  imageRelPath,
  MAX_CAPTURE_IMAGES_WARN,
  type MemoryCard,
  type SourceKind,
} from '@findr/core';

import { saveAudioFile, saveImageAsWebp, type SourceImage } from './compress';
import type { RuntimeState } from '@/platform/runtime';

export function newCardId(): string {
  return Crypto.randomUUID();
}

export interface CaptureSubmission {
  images: SourceImage[];
  /** 录音的临时文件 uri */
  audioUri?: string | null;
  text?: string | null;
  vision: boolean;
}

export interface OverImageLimitInfo {
  count: number;
  limit: number;
}

/** 超过阈值只是提示确认，不做硬截断（需求 5.1） */
export function overImageLimit(count: number): OverImageLimitInfo | null {
  return count > MAX_CAPTURE_IMAGES_WARN ? { count, limit: MAX_CAPTURE_IMAGES_WARN } : null;
}

/**
 * 落盘 + 插行。**先写文件再插行**，所以即使下一句推进失败，素材也已经在库里了。
 * 返回草稿卡，调用方拿到就可以立刻渲染，不必等模型。
 */
export async function persistCapture(
  rt: RuntimeState,
  input: CaptureSubmission,
): Promise<MemoryCard> {
  const id = newCardId();
  const now = new Date();

  const imageRels: string[] = [];
  for (let i = 0; i < input.images.length; i++) {
    const rel = imageRelPath(now, id, i);
    await saveImageAsWebp(input.images[i], rel);
    imageRels.push(rel);
  }

  let audioRel: string | null = null;
  if (input.audioUri) {
    audioRel = audioRelPath(now, id);
    await saveAudioFile(input.audioUri, audioRel);
  }

  const text = input.text?.trim() ? input.text.trim() : null;
  const source: SourceKind = imageRels.length > 0 ? 'photo' : audioRel ? 'voice' : 'text';

  return createDraft(
    { db: rt.driver },
    {
      source,
      text,
      images: imageRels.length > 0 ? imageRels : null,
      audio: audioRel,
    },
    { id, now },
  );
}
