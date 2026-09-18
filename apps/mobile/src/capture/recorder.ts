import { useCallback, useRef } from 'react';
import {
  RecordingPresets,
  requestRecordingPermissionsAsync,
  setAudioModeAsync,
  useAudioRecorder,
  useAudioRecorderState,
} from 'expo-audio';

import { MIN_RECORDING_MS } from '@findr/core';

export interface RecordedAudio {
  uri: string;
  durationMs: number;
}

/** 长按录音（需求 5.1）：按下开始、松开结束，输出 m4a/AAC 不转码 */
export function useLongPressRecorder() {
  const recorder = useAudioRecorder(RecordingPresets.HIGH_QUALITY);
  const state = useAudioRecorderState(recorder);
  const startedAt = useRef<number | null>(null);
  const busy = useRef(false);

  const start = useCallback(async () => {
    if (busy.current || recorder.isRecording) return;
    busy.current = true;
    try {
      const permission = await requestRecordingPermissionsAsync();
      if (!permission.granted) throw new Error('没有麦克风权限，无法录音');

      // 录音期间要让音频会话进入录制模式，否则部分机型录不到声音
      await setAudioModeAsync({ allowsRecording: true, playsInSilentMode: true });
      await recorder.prepareToRecordAsync();
      recorder.record();
      startedAt.current = Date.now();
    } finally {
      busy.current = false;
    }
  }, [recorder]);

  /** 返回 null 表示这次是误触（太短或没拿到文件），不该生成卡片 */
  const stop = useCallback(async (): Promise<RecordedAudio | null> => {
    if (!recorder.isRecording && startedAt.current == null) return null;
    const durationMs = startedAt.current ? Date.now() - startedAt.current : 0;
    startedAt.current = null;

    await recorder.stop();
    const uri = recorder.uri;
    if (!uri || durationMs < MIN_RECORDING_MS) return null;
    return { uri, durationMs };
  }, [recorder]);

  return {
    start,
    stop,
    isRecording: state.isRecording,
    durationMs: state.durationMillis,
  };
}
