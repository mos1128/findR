import { useCallback, useMemo, useState } from 'react';
import { Alert, Image, Pressable, StyleSheet, Switch, Text, View } from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';
import {
  MAX_CAPTURE_IMAGES_WARN,
  effectiveVision,
  writeCaptureSettings,
} from '@findr/core';

import { Radius, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { Button, Field, Panel, Screen, SectionTitle } from '@/ui/kit';
import { runQueueNow, useRuntime, visionSupported } from '@/platform/runtime';
import { CameraModal } from '@/capture/CameraModal';
import { pickImagesFromLibrary, type PickedImage } from '@/capture/picker';
import { persistCapture } from '@/capture/submit';
import { useLongPressRecorder } from '@/capture/recorder';

export default function CaptureScreen() {
  const theme = useTheme();
  const router = useRouter();
  const params = useLocalSearchParams<{ mode?: string }>();
  const { state: rt, refresh } = useRuntime();
  const recorder = useLongPressRecorder();

  const [images, setImages] = useState<PickedImage[]>([]);
  const [text, setText] = useState('');
  const [audio, setAudio] = useState<{ uri: string; durationMs: number } | null>(null);
  const [cameraOpen, setCameraOpen] = useState(params.mode === 'photo');
  const [visionOverride, setVisionOverride] = useState<boolean | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const visionCapable = useMemo(() => (rt ? visionSupported(rt.llm) : true), [rt]);
  // 默认值来自设置，但本次可随时切换（需求 5.1）
  const vision = visionOverride ?? (rt ? effectiveVision(rt.capture, visionCapable) : true);
  const visionLocked = !visionCapable;

  const addImages = useCallback((picked: PickedImage[]) => {
    setImages((prev) => {
      const next = [...prev, ...picked];
      if (next.length > MAX_CAPTURE_IMAGES_WARN) {
        Alert.alert(
          '图片有点多',
          `这张卡已经有 ${next.length} 张图（建议不超过 ${MAX_CAPTURE_IMAGES_WARN} 张）。继续也可以，只是会更占存储。`,
        );
      }
      return next;
    });
  }, []);

  const openLibrary = async () => {
    try {
      addImages(await pickImagesFromLibrary());
    } catch (e) {
      Alert.alert('打不开相册', e instanceof Error ? e.message : String(e));
    }
  };

  const toggleRecording = async () => {
    if (recorder.isRecording) {
      const recorded = await recorder.stop();
      if (recorded) setAudio(recorded);
      else Alert.alert('这段太短了', '按住多说一会儿再松开。');
      return;
    }
    try {
      await recorder.start();
    } catch (e) {
      Alert.alert('录不了音', e instanceof Error ? e.message : String(e));
    }
  };

  const doSubmit = async () => {
    if (!rt) return;
    setSubmitting(true);
    try {
      await persistCapture(rt, {
        images,
        audioUri: audio?.uri ?? null,
        text,
        vision,
      });
      // 记住这次的选择，下次默认沿用（需求 5.1）
      if (visionOverride !== null) {
        writeCaptureSettings(rt.driver, { ...rt.capture, visionLast: visionOverride });
      }
      router.back();
      // 先让界面回到记忆流，再在后台推进；失败也有队列在回前台时兜底
      void runQueueNow(rt, { vision }).then(() => refresh());
    } catch (e) {
      Alert.alert('保存失败', e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  };

  const onSubmit = () => {
    if (!rt) return;
    const hasText = text.trim().length > 0;
    if (images.length === 0 && !audio && !hasText) {
      Alert.alert('还是空的', '拍张照、说一句，或者打几个字。');
      return;
    }
    // 关掉图片分析又没有文字：没有任何可抽取的信息源（需求 5.1）
    if (!vision && images.length > 0 && !hasText) {
      Alert.alert(
        '没有可分析的内容',
        '打开图片分析，或者补一句话。也可以存成纯图片卡片——之后只能靠分类和标签找到它。',
        [
          { text: '继续编辑', style: 'cancel' },
          { text: '存为纯图片卡片', style: 'destructive', onPress: () => void doSubmit() },
        ],
      );
      return;
    }
    void doSubmit();
  };

  return (
    <Screen>
      <Panel>
        <SectionTitle hint="首张全貌 → 局部 → 特写">图片</SectionTitle>
        <View style={styles.thumbs}>
          {images.map((img, i) => (
            <Pressable
              key={`${img.uri}-${i}`}
              onLongPress={() => setImages((prev) => prev.filter((_, idx) => idx !== i))}>
              <Image source={{ uri: img.uri }} style={styles.thumb} />
            </Pressable>
          ))}
          <Pressable
            onPress={() => setCameraOpen(true)}
            style={[styles.addThumb, { borderColor: theme.border, backgroundColor: theme.surfaceAlt }]}>
            <Text style={{ color: theme.textSecondary, fontSize: 20 }}>＋</Text>
          </Pressable>
        </View>
        <View style={styles.row}>
          <Button title="拍照 / 连拍" variant="secondary" compact onPress={() => setCameraOpen(true)} />
          <Button title="从相册选" variant="secondary" compact onPress={() => void openLibrary()} />
          {images.length > 0 ? (
            <Button title="清空" variant="ghost" compact onPress={() => setImages([])} />
          ) : null}
        </View>
        <Text style={[styles.hint, { color: theme.textMuted }]}>
          长按缩略图可以删掉某一张。张数不限。
        </Text>

        <View style={[styles.visionRow, { borderColor: theme.border }]}>
          <View style={{ flex: 1 }}>
            <Text style={{ color: theme.text, fontSize: 14, fontWeight: '500' }}>图片分析</Text>
            <Text style={{ color: theme.textMuted, fontSize: 11, lineHeight: 15 }}>
              {visionLocked
                ? '当前模型无视觉能力，图片仅作附件保存（需换模型才能开启）'
                : vision
                  ? '图片会随文字一起送给模型，图里的内容能被搜到'
                  : '不发送图片，图中内容不会被搜到；之后可以「补分析图片」'}
            </Text>
          </View>
          <Switch
            value={vision}
            disabled={visionLocked}
            onValueChange={setVisionOverride}
            trackColor={{ true: theme.record, false: theme.surfaceAlt }}
          />
        </View>
      </Panel>

      <Panel>
        <SectionTitle hint="转写结果可编辑">说一句 / 打一句</SectionTitle>
        <Field
          label="口述原文"
          value={text}
          onChangeText={setText}
          placeholder="例如：备用手电筒放主卧衣柜最下层纸箱了"
          multiline
        />
      </Panel>

      <Panel>
        <SectionTitle hint="按住说话，松开结束">语音</SectionTitle>
        {audio ? (
          <View style={styles.row}>
            <Text style={{ color: theme.success, flex: 1 }}>
              已录 {Math.round(audio.durationMs / 1000)} 秒
            </Text>
            <Button title="重录" variant="ghost" compact onPress={() => setAudio(null)} />
          </View>
        ) : (
          <Button
            title={recorder.isRecording ? `● 录音中 ${Math.round(recorder.durationMs / 1000)}s` : '长按录音'}
            variant={recorder.isRecording ? 'danger' : 'secondary'}
            onPress={() => void toggleRecording()}
          />
        )}
        <Text style={[styles.hint, { color: theme.textMuted }]}>
          {rt?.asr
            ? '录音会送去你配置的 ASR 转成文字。'
            : '还没配置 ASR：录音会先存好，之后补一句话就能解析。'}
        </Text>
      </Panel>

      <Button title="存进记忆流" loading={submitting} onPress={onSubmit} />

      <CameraModal
        visible={cameraOpen}
        onClose={() => setCameraOpen(false)}
        onConfirm={addImages}
      />
    </Screen>
  );
}

const styles = StyleSheet.create({
  thumbs: { flexDirection: 'row', flexWrap: 'wrap', gap: Spacing.two },
  thumb: { width: 72, height: 72, borderRadius: Radius.sm },
  addThumb: {
    width: 72,
    height: 72,
    borderRadius: Radius.sm,
    borderWidth: StyleSheet.hairlineWidth,
    alignItems: 'center',
    justifyContent: 'center',
  },
  row: { flexDirection: 'row', gap: Spacing.two, alignItems: 'center', flexWrap: 'wrap' },
  visionRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.three,
    borderTopWidth: StyleSheet.hairlineWidth,
    paddingTop: Spacing.three,
    marginTop: Spacing.one,
  },
  hint: { fontSize: 11, lineHeight: 15 },
});
