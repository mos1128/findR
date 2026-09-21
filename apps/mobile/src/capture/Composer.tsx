import { useState } from 'react';
import { Alert, Image, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { effectiveVision, MAX_CAPTURE_IMAGES_WARN, writeCaptureSettings } from '@findr/core';

import { Radius, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { visionSupported, type RuntimeState } from '@/platform/runtime';

import { CameraModal } from './CameraModal';
import { pickTextFile, type PickedTextFile } from './files';
import { pickImagesFromLibrary, type PickedImage } from './picker';
import { useLongPressRecorder } from './recorder';
import { persistCapture } from './submit';

/**
 * 底部**唯一的**录入入口（第十七版）。
 *
 * 改之前是四个按钮、两条路：`📷 → /capture?mode=photo` 与 `⌨️ → /capture?mode=text`
 * 通到**同一个**采集页（三个面板全在，只差初始相机开不开），而 `🎙️ 长按` 又完全不走那里
 * —— 直接 `persistCapture` 落盘。用户无从预判，而且**打字比语音多两步**
 * （进页面 → 再点一次输入框：`Field` 没有 `autoFocus`）。
 *
 * 现在收成一条：`[＋] [输入框] [存] [🎙️]`
 * - 打字：回车即存（与语音对等，一步落盘）
 * - ＋：就地展开「拍照 / 从相册选 / 选文本文件」，**不跳页**
 * - 🎙️：长按录、松开存；有文字/图片/文件时一并带上（需求 5.1「边拍边说」）
 * - 图片分析开关：有图片时常驻在附件条右侧，关掉的代价就在下面一行写着
 *
 * **刻意不做的事：把「记」和「查」合并成同一个框由模型自动分路。**
 * 判错的代价不对称：「查」判成「记」只是多一条垃圾卡（看得见、能删）；
 * 「记」判成「查」是**用户以为存下了其实没存**，不可发现，且与
 * 「先落盘、素材永不丢失」这条红线直接冲突。顶部搜索框照旧单独存在（需求六：
 * 「查」与「记」必须强视觉区分，避免误用）。
 */
export function Composer({
  rt,
  onSubmitted,
}: {
  rt: RuntimeState | null;
  /** 存下之后：调用方去刷新记忆流并把这张卡推进解析队列（`vision` 必须原样带过去） */
  onSubmitted: (vision: boolean) => void;
}) {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const recorder = useLongPressRecorder();

  const [text, setText] = useState('');
  const [images, setImages] = useState<PickedImage[]>([]);
  const [files, setFiles] = useState<PickedTextFile[]>([]);
  const [expanded, setExpanded] = useState(false);
  const [cameraOpen, setCameraOpen] = useState(false);
  /** 本次录入的图片分析选择（null = 跟随设置里的默认值 / 上次选择） */
  const [visionOverride, setVisionOverride] = useState<boolean | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const capable = rt ? visionSupported(rt.llm) : true;
  const vision = visionOverride ?? (rt ? effectiveVision(rt.capture, capable) : true);
  const textSource = `${text.trim()}${files.map((f) => f.text).join('\n')}`;
  const hasContent = textSource.length > 0 || images.length > 0;
  const offline = !rt;

  const fail = (e: unknown) => (e instanceof Error ? e.message : String(e));

  const addImages = (picked: PickedImage[]) => {
    if (picked.length === 0) return;
    setImages((prev) => {
      const next = [...prev, ...picked];
      if (next.length > MAX_CAPTURE_IMAGES_WARN) {
        Alert.alert(
          '图片有点多',
          `这条已经有 ${next.length} 张图（建议不超过 ${MAX_CAPTURE_IMAGES_WARN} 张）。继续也可以，只是会更占存储。`,
        );
      }
      return next;
    });
    setExpanded(false);
  };

  const openLibrary = async () => {
    setExpanded(false);
    try {
      addImages(await pickImagesFromLibrary());
    } catch (e) {
      Alert.alert('打不开相册', fail(e));
    }
  };

  const openFile = async () => {
    setExpanded(false);
    try {
      const picked = await pickTextFile();
      if (picked) setFiles((prev) => [...prev, picked]);
    } catch (e) {
      Alert.alert('没能读这个文件', fail(e));
    }
  };

  const persist = async (audioUri: string | null, body: string) => {
    if (!rt) return;
    setSubmitting(true);
    try {
      // 记住这次的选择，下次默认沿用（需求 5.1）
      if (visionOverride !== null) {
        writeCaptureSettings(rt.driver, { ...rt.capture, visionLast: visionOverride });
      }
      await persistCapture(rt, { images, audioUri, text: body, vision });
      setText('');
      setImages([]);
      setFiles([]);
      setExpanded(false);
      onSubmitted(vision);
    } catch (e) {
      Alert.alert('没能存下', fail(e));
    } finally {
      setSubmitting(false);
    }
  };

  const submit = (audioUri: string | null = null) => {
    if (!rt || submitting) return;
    const body = [text.trim(), ...files.map((f) => f.text)].filter(Boolean).join('\n\n');
    if (images.length === 0 && !audioUri && !body) {
      Alert.alert('还是空的', '拍张照、说一句，或者打几个字。');
      return;
    }
    // 关掉图片分析又没有文字：没有任何可抽取的信息源（需求 5.1）
    if (!vision && images.length > 0 && !body) {
      Alert.alert(
        '没有可分析的内容',
        '打开图片分析，或者补一句话。也可以存成纯图片卡片——之后只能靠分类和标签找到它。',
        [
          { text: '继续编辑', style: 'cancel' },
          { text: '存为纯图片卡片', style: 'destructive', onPress: () => void persist(audioUri, body) },
        ],
      );
      return;
    }
    void persist(audioUri, body);
  };

  const onVoicePressIn = async () => {
    if (!rt || submitting) return;
    setExpanded(false);
    try {
      await recorder.start();
    } catch (e) {
      Alert.alert('录不了音', fail(e));
    }
  };

  const onVoicePressOut = async () => {
    const audio = await recorder.stop();
    // 按下就松开（误触）：既不弹窗打扰，也不生成一张空卡
    if (!audio) return;
    submit(audio.uri);
  };

  const canSend = hasContent && !submitting;

  return (
    <View
      style={[
        styles.bar,
        { backgroundColor: theme.surface, borderColor: theme.border, paddingBottom: insets.bottom + 8 },
      ]}>
      {images.length > 0 || files.length > 0 ? (
        <View style={styles.attachRow}>
          <ScrollView
            horizontal
            showsHorizontalScrollIndicator={false}
            style={styles.attachScroll}
            contentContainerStyle={styles.attachList}>
            {images.map((img, i) => (
              <View key={`${img.uri}-${i}`} style={styles.thumbWrap}>
                <Image source={{ uri: img.uri }} style={[styles.thumb, { borderColor: theme.border }]} />
                <Pressable
                  onPress={() => setImages((prev) => prev.filter((_, idx) => idx !== i))}
                  hitSlop={6}
                  style={[styles.removeBadge, { backgroundColor: theme.danger }]}>
                  <Text style={styles.removeText}>✕</Text>
                </Pressable>
              </View>
            ))}
            {files.map((f, i) => (
              <View key={`${f.name}-${i}`} style={[styles.fileChip, { borderColor: theme.border, backgroundColor: theme.surfaceAlt }]}>
                <Text style={[styles.fileText, { color: theme.textSecondary }]} numberOfLines={1}>
                  📄 {f.name} · {f.chars} 字
                </Text>
                <Pressable
                  onPress={() => setFiles((prev) => prev.filter((_, idx) => idx !== i))}
                  hitSlop={6}>
                  <Text style={{ color: theme.textMuted, fontSize: 12 }}>✕</Text>
                </Pressable>
              </View>
            ))}
          </ScrollView>

          {/* 开关常驻（需求 5.1）：模型没有视觉能力时锁定，并说明图片只是附件 */}
          {images.length > 0 ? (
            <Pressable
              disabled={!capable}
              onPress={() => setVisionOverride(!vision)}
              style={[
                styles.visionChip,
                {
                  borderColor: vision ? theme.record : theme.border,
                  backgroundColor: vision ? theme.record : theme.surfaceAlt,
                },
              ]}>
              <Text style={{ color: vision ? '#ffffff' : theme.textSecondary, fontSize: 12 }}>
                图片分析·{capable ? (vision ? '开' : '关') : '不可用'}
              </Text>
            </Pressable>
          ) : null}
        </View>
      ) : null}

      {images.length > 0 && (!vision || !capable) ? (
        <Text style={[styles.hint, { color: theme.textMuted }]}>
          {capable
            ? '图片不发给模型，图里的内容不会被搜到（之后可以「补分析图片」）'
            : '当前模型无视觉能力，图片仅作附件保存'}
        </Text>
      ) : null}

      {recorder.isRecording ? (
        <Text style={[styles.hint, { color: theme.danger }]}>
          ● 录音中 {Math.round(recorder.durationMs / 1000)}s · 松开结束
        </Text>
      ) : expanded ? (
        <View style={styles.expandRow}>
          <Pressable
            onPress={() => setCameraOpen(true)}
            style={[styles.expandItem, { borderColor: theme.record, backgroundColor: theme.surfaceAlt }]}>
            <Text style={{ color: theme.record, fontSize: 13 }}>📷 拍照 / 连拍</Text>
          </Pressable>
          <Pressable
            onPress={() => void openLibrary()}
            style={[styles.expandItem, { borderColor: theme.border, backgroundColor: theme.surfaceAlt }]}>
            <Text style={{ color: theme.textSecondary, fontSize: 13 }}>🖼 从相册选</Text>
          </Pressable>
          <Pressable
            onPress={() => void openFile()}
            style={[styles.expandItem, { borderColor: theme.border, backgroundColor: theme.surfaceAlt }]}>
            <Text style={{ color: theme.textSecondary, fontSize: 13 }}>📄 文本文件</Text>
          </Pressable>
        </View>
      ) : null}

      <View style={styles.inputRow}>
        <Pressable
          onPress={() => setExpanded((v) => !v)}
          disabled={offline}
          hitSlop={4}
          style={[
            styles.plus,
            { borderColor: expanded ? theme.record : theme.border, backgroundColor: theme.surfaceAlt },
          ]}>
          <Text style={{ color: expanded ? theme.record : theme.textSecondary, fontSize: 18 }}>
            {expanded ? '✕' : '＋'}
          </Text>
        </Pressable>

        <TextInput
          value={text}
          onChangeText={setText}
          onSubmitEditing={() => submit()}
          returnKeyType="done"
          editable={!offline}
          placeholder={offline ? '数据库还没就绪' : '说点什么，回车即存'}
          placeholderTextColor={theme.textMuted}
          style={[
            styles.input,
            { color: theme.text, borderColor: theme.border, backgroundColor: theme.surfaceAlt },
          ]}
        />

        {canSend ? (
          <Pressable
            onPress={() => submit()}
            style={[styles.send, { backgroundColor: theme.record }]}>
            <Text style={{ color: '#ffffff', fontSize: 14, fontWeight: '600' }}>存</Text>
          </Pressable>
        ) : null}

        <Pressable
          onPressIn={() => void onVoicePressIn()}
          onPressOut={() => void onVoicePressOut()}
          disabled={offline || submitting}
          style={[
            styles.mic,
            { backgroundColor: recorder.isRecording ? theme.danger : theme.record, opacity: offline ? 0.4 : 1 },
          ]}>
          <Text style={{ fontSize: 17 }}>{recorder.isRecording ? '●' : '🎙️'}</Text>
        </Pressable>
      </View>

      <CameraModal visible={cameraOpen} onClose={() => setCameraOpen(false)} onConfirm={addImages} />
    </View>
  );
}

const styles = StyleSheet.create({
  bar: {
    borderTopWidth: StyleSheet.hairlineWidth,
    paddingHorizontal: Spacing.three,
    paddingTop: Spacing.two,
    gap: Spacing.two,
  },
  attachRow: { flexDirection: 'row', alignItems: 'center', gap: Spacing.two },
  /**
   * 横向附件条必须 `flex: 1`：不写的话它按内容撑宽，会把右边的「图片分析」开关
   * 顶出屏幕外（横向 ScrollView 在 row 里的默认宽度就是内容宽度）。
   */
  attachScroll: { flex: 1 },
  /** 纵向留 6px：缩略图右上角的 ✕ 是 `top:-6` 的，没有留白会被 ScrollView 裁掉一半 */
  attachList: { flexDirection: 'row', gap: Spacing.two, alignItems: 'center', paddingVertical: 6, paddingRight: 6 },
  thumbWrap: { width: 64, height: 64 },
  thumb: { width: 64, height: 64, borderRadius: Radius.sm, borderWidth: StyleSheet.hairlineWidth },
  /** 删除角标是缩略图的子元素，不是浮层 —— 别改成全屏 absolute */
  removeBadge: {
    position: 'absolute',
    top: -6,
    right: -6,
    width: 20,
    height: 20,
    borderRadius: 10,
    alignItems: 'center',
    justifyContent: 'center',
  },
  removeText: { color: '#ffffff', fontSize: 11, fontWeight: '600' },
  fileChip: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    borderRadius: Radius.pill,
    borderWidth: StyleSheet.hairlineWidth,
    paddingHorizontal: 10,
    paddingVertical: 6,
    maxWidth: 220,
  },
  fileText: { fontSize: 12, flexShrink: 1 },
  visionChip: {
    borderRadius: Radius.pill,
    borderWidth: StyleSheet.hairlineWidth,
    paddingHorizontal: 10,
    paddingVertical: 6,
  },
  hint: { fontSize: 11, lineHeight: 15 },
  expandRow: { flexDirection: 'row', gap: Spacing.two, flexWrap: 'wrap' },
  expandItem: {
    borderRadius: Radius.pill,
    borderWidth: StyleSheet.hairlineWidth,
    paddingHorizontal: 12,
    paddingVertical: 7,
  },
  inputRow: { flexDirection: 'row', alignItems: 'center', gap: Spacing.two },
  plus: {
    width: 40,
    height: 40,
    borderRadius: 20,
    borderWidth: StyleSheet.hairlineWidth,
    alignItems: 'center',
    justifyContent: 'center',
  },
  input: {
    flex: 1,
    borderRadius: Radius.pill,
    borderWidth: StyleSheet.hairlineWidth,
    paddingHorizontal: Spacing.three,
    paddingVertical: 9,
    fontSize: 15,
  },
  send: {
    borderRadius: Radius.pill,
    paddingHorizontal: 16,
    paddingVertical: 10,
    alignItems: 'center',
    justifyContent: 'center',
  },
  mic: { width: 40, height: 40, borderRadius: 20, alignItems: 'center', justifyContent: 'center' },
});
