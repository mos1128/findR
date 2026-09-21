import { useCallback, useMemo, useState } from 'react';
import {
  Alert,
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { Image } from 'expo-image';
import { useAudioPlayer, useAudioPlayerStatus } from 'expo-audio';
import {
  advanceCard,
  badgeLabel,
  canReanalyze,
  cardBadges,
  deleteCard,
  getCard,
  listCategories,
  listLocations,
  reanalyzeCard,
  regenerateDesc,
  reorganizeCard,
  setCardStatus,
  updateCardFields,
  type Category,
  type LocationNode,
  type MemoryCard,
  type StepItem,
} from '@findr/core';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { Radius, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { Badge, Button, Chip, Field, ListRow, Panel, Screen, SectionTitle } from '@/ui/kit';
import { mediaUri } from '@/platform/media';
import { currentVision, requireDeps, useRuntime, visionSupported } from '@/platform/runtime';

/** 秒 → m:ss。duration 在音频还没加载出来时是 0，此时显示 --:-- 而不是 0:00 */
function fmtClock(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return '--:--';
  const s = Math.floor(seconds);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

export default function CardDetailScreen() {
  const theme = useTheme();
  const router = useRouter();
  const { id } = useLocalSearchParams<{ id: string }>();
  const { state: rt, refresh } = useRuntime();
  const [tick, setTick] = useState(0);

  const card = useMemo<MemoryCard | undefined>(
    () => (rt && id ? getCard(rt.driver, id) : undefined),
    // tick 用来在写库后强制重读
    [rt, id, tick],
  );
  const categories: Category[] = useMemo(
    () => (rt ? listCategories(rt.driver) : []),
    [rt, tick],
  );
  const locations: LocationNode[] = useMemo(
    () => (rt ? listLocations(rt.driver) : []),
    [rt, tick],
  );

  const [pickerOpen, setPickerOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  /** 「步骤」按内容出现：有步骤时自动展开，没有则收起 —— 多数记忆本来就没有步骤 */
  const [stepsOpen, setStepsOpen] = useState(false);

  const player = useAudioPlayer(card?.audioPath ? { uri: mediaUri(card.audioPath) } : null);
  const playerStatus = useAudioPlayerStatus(player);

  const reload = useCallback(() => setTick((t) => t + 1), []);

  if (!rt) return <Screen />;
  if (!card) {
    return (
      <Screen>
        <Text style={{ color: theme.textSecondary }}>卡片不存在，可能已被删除。</Text>
      </Screen>
    );
  }

  const ctx = {
    visionSupported: visionSupported(rt.llm),
    asrConfigured: !!rt.asr,
  };
  const badges = cardBadges(card);
  const images = card.images ?? [];
  const steps = card.steps ?? [];
  /** 有步骤就默认展开 —— 是流程才会解析出 steps，没步骤的卡不该白占一块面板 */
  const showSteps = stepsOpen || steps.length > 0;

  const patch = (fields: Parameters<typeof updateCardFields>[2]) => {
    updateCardFields(rt.driver, card.id, fields, new Date());
    reload();
  };

  const runAction = async (
    fn: (deps: ReturnType<typeof requireDeps>) => Promise<unknown>,
    label: string,
  ) => {
    setBusy(true);
    try {
      const res = await fn(requireDeps(rt));
      reload();
      const outcome = (res as { outcome?: string; ok?: boolean } | undefined)?.outcome;
      if (outcome === 'retry') Alert.alert(`${label}失败`, '稍后可以再试一次。');
      else if (outcome === 'skipped-not-pending') {
        /* 无需提示 */
      }
    } catch (e) {
      Alert.alert(`${label}失败`, e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const onDelete = () => {
    Alert.alert('删除这张卡片？', '卡片和它的图片、录音都会一起删掉，不可恢复。', [
      { text: '取消', style: 'cancel' },
      {
        text: '删除',
        style: 'destructive',
        onPress: () => {
          deleteCard(rt.driver, card.id);
          router.back();
        },
      },
    ]);
  };

  return (
    <Screen>
      {/*
        详情页首屏 = 用户自己录进来的原始素材：原文 → 音频 → 照片。
        以前这段是错的：照片**压根没渲染**（只有记忆流列表里的缩略图），
        原文藏在「描述」面板的第 4 个输入框里，音频播放器排在第三个面板 ——
        用户点进来第一眼看不到「我记了什么」，只看到一堆分类/状态选择器。
      */}
      <Panel>
        <View style={styles.headerRow}>
          <Text style={[styles.title, { color: theme.text }]} numberOfLines={3}>
            {card.entity ?? card.desc?.slice(0, 40) ?? '（待整理）'}
          </Text>
        </View>
        <View style={styles.badges}>
          {badges.map((b) => (
            <Badge key={b} label={badgeLabel(b, ctx)} tone="confirm" />
          ))}
          {card.status === 'archived' ? <Badge label="已归档" /> : null}
          <Badge label={`${card.source === 'photo' ? '拍照' : card.source === 'voice' ? '语音' : '文字'}`} />
        </View>
        {card.ask ? (
          <Text style={{ color: theme.badgeConfirm, fontSize: 13 }}>想确认：{card.ask}</Text>
        ) : null}
        {card.pathSuggestion && !card.pathNames ? (
          <Text style={{ color: theme.textSecondary, fontSize: 12 }}>
            模型猜的位置：{card.pathSuggestion}
          </Text>
        ) : null}

        <SectionTitle hint="在下面「卡片文字」里可以改">原文</SectionTitle>
        {card.transcript ? (
          <Text style={{ color: theme.text, fontSize: 15, lineHeight: 23 }}>{card.transcript}</Text>
        ) : (
          <Text style={{ color: theme.textMuted, fontSize: 13, lineHeight: 19 }}>
            {card.audioPath
              ? '还没有文字。在下面「卡片文字 → 口述原文」里补一句，这张卡就能解析入库。'
              : '没有原文。'}
          </Text>
        )}

        {card.audioPath ? (
          <View style={styles.audioRow}>
            <Button
              title={playerStatus.playing ? '⏸ 暂停' : '▶ 播放录音'}
              variant="secondary"
              compact
              onPress={() => (playerStatus.playing ? player.pause() : player.play())}
            />
            <Text style={{ color: theme.textMuted, fontSize: 12 }}>
              {fmtClock(playerStatus.currentTime)} / {fmtClock(playerStatus.duration)}
            </Text>
          </View>
        ) : null}

        {images.length > 0 ? (
          <>
            <SectionTitle hint={`${images.length} 张`}>照片</SectionTitle>
            <ScrollView
              horizontal
              showsHorizontalScrollIndicator={false}
              contentContainerStyle={styles.photoStrip}>
              {images.map((rel) => (
                <Image
                  key={rel}
                  source={{ uri: mediaUri(rel) }}
                  style={styles.photo}
                  contentFit="cover"
                />
              ))}
            </ScrollView>
          </>
        ) : null}
      </Panel>

      {card.retryCount > 0 || card.status === 'pending' || card.status === 'pending_transcript' || card.needsOrganize ? (
        <Panel>
          <SectionTitle hint="解决后角标即消失">待办</SectionTitle>
          {card.needsOrganize ? (
            <Button
              title="重新整理"
              loading={busy}
              onPress={() => void runAction((deps) => reorganizeCard(deps, card.id), '重新整理')}
            />
          ) : null}
          {canReanalyze(card, ctx) ? (
            <Button
              title="补分析图片"
              variant="secondary"
              loading={busy}
              onPress={() =>
                Alert.alert('补分析会覆盖结构化字段', '模型重跑后，实体名、位置、标签等都会按图片重写。', [
                  { text: '取消', style: 'cancel' },
                  {
                    text: '继续',
                    onPress: () =>
                      void runAction((deps) => reanalyzeCard(deps, card.id), '补分析'),
                  },
                ])
              }
            />
          ) : null}
          {!card.needsOrganize && card.status === 'active' ? (
            <Button
              title="重新生成描述"
              variant="secondary"
              loading={busy}
              onPress={() =>
                void runAction((deps) => regenerateDesc(deps, card.id), '重新生成描述')
              }
            />
          ) : null}
          {card.status === 'pending' || card.status === 'pending_transcript' ? (
            <Button
              title="立即重试一次"
              variant="secondary"
              loading={busy}
              onPress={() =>
                void runAction(
                  (deps) => advanceCard(deps, card.id, { vision: currentVision(rt) }),
                  '重试',
                )
              }
            />
          ) : null}
          {card.lastError ? (
            <Text style={{ color: theme.textMuted, fontSize: 11 }}>上次错误：{card.lastError}</Text>
          ) : null}
        </Panel>
      ) : null}

      {/*
        分类是唯一的组织维度。这里以前还并排放着「结构类型」和「业务状态」两组 chip ——
        结构类型对检索零影响、又和分类一一对应（看着就是说两遍），业务状态更是覆盖不全的
        自造枚举，都已整体移除。详见《开发交接.md》与 db/schema.ts 的 v2 迁移。
      */}
      <Panel>
        <SectionTitle hint="AI 自动归类，可随时更正">分类</SectionTitle>
        <View style={styles.row}>
          {categories.map((c) => (
            <Chip
              key={c.id}
              label={`${c.emoji ?? ''}${c.name}`}
              active={card.categoryId === c.id}
              onPress={() => patch({ categoryId: c.id })}
            />
          ))}
        </View>

        <SectionTitle hint="内容里说了就自动记，没说不强求">位置</SectionTitle>
        {/*
          位置的来源已经变了：解析卡片时自动匹配/新建，用户来这里只是「看一眼、改一改」。
          旧文案写的是「从已有位置树里选」，配合一个空位置树，等于逼用户先去手工建房间。
          去掉了「仅物品类必填」之后，位置对任何一条记忆都可选 —— 说「把护照放回主卧抽屉」
          本来就是既像待办又带位置。
        */}
        <ListRow
          title={card.pathNames ?? '还没记录位置'}
          subtitle={
            card.pathNames
              ? card.pathMatched === false
                ? '解析时新建的位置，不对可以改'
                : '解析时自动记录；点这里可以改到别处'
              : '解析这条卡片时如果提到了位置会自动记录；也可以现在手动选一个'
          }
          onPress={() => setPickerOpen(true)}
          right={<Text style={{ color: theme.record }}>{card.pathNames ? '修改' : '选择'}</Text>}
        />
        {card.pathNames ? (
          <Button
            title="清除位置"
            variant="ghost"
            compact
            onPress={() => patch({ pathIds: null, pathNames: null })}
          />
        ) : null}
      </Panel>

      <Panel>
        <SectionTitle hint="改完可以重新生成描述">卡片文字</SectionTitle>
        <Field
          label="口述原文"
          hint="顶部「原文」显示的就是这里的内容"
          value={card.transcript ?? ''}
          onChangeText={(v) => patch({ transcript: v })}
          multiline
        />
        <Field
          label="描述"
          value={card.desc ?? ''}
          onChangeText={(v) => patch({ desc: v })}
          multiline
        />
        <Field
          label="实体名"
          value={card.entity ?? ''}
          onChangeText={(v) => patch({ entity: v })}
          placeholder="规范名称，如「备用手电筒」"
        />
        <Field
          label="标签"
          value={(card.tags ?? []).join('、')}
          onChangeText={(v) =>
            patch({ tags: v.split(/[、,，\s]+/).map((s) => s.trim()).filter(Boolean) })
          }
          placeholder="用、或逗号分隔"
        />
      </Panel>

      {/*
        步骤按内容出现。以前这里挂的是 `structureType !== 'item'`，等于按类型一刀切；
        现在模型只有在内容本身是一串步骤/清单时才会返回 steps，所以用 steps 是否有值来定。
        没有步骤时保留一个折叠入口，方便用户自己补。
      */}
      <Panel>
        <Pressable onPress={() => setStepsOpen((v) => !v)} style={styles.collapseHeader}>
          <Text
            style={{ color: theme.textSecondary, fontSize: 13, fontWeight: '600', letterSpacing: 0.3 }}>
            步骤{steps.length > 0 ? `（${steps.length}）` : '（没有）'}
          </Text>
          <Text style={{ color: theme.record, fontSize: 13 }}>{showSteps ? '收起' : '展开'}</Text>
        </Pressable>
        {showSteps ? (
          <StepEditor
            steps={steps}
            onChange={(next) => patch({ steps: next.length > 0 ? next : null })}
          />
        ) : null}
      </Panel>

      <Panel>
        <SectionTitle>其他操作</SectionTitle>
        {card.status === 'archived' ? (
          <Button
            title="恢复到记忆流"
            variant="secondary"
            onPress={() => {
              setCardStatus(rt.driver, card.id, 'active', new Date());
              reload();
            }}
          />
        ) : (
          <Button
            title="归档（移出检索）"
            variant="secondary"
            onPress={() => {
              setCardStatus(rt.driver, card.id, 'archived', new Date());
              reload();
            }}
          />
        )}
        <Button title="删除卡片" variant="danger" onPress={onDelete} />
      </Panel>

      <LocationPickerModal
        visible={pickerOpen}
        locations={locations}
        onClose={() => setPickerOpen(false)}
        onPick={(ids, names) => {
          patch({ pathIds: ids, pathNames: names, pathSuggestion: null });
          setPickerOpen(false);
        }}
      />
      <View style={{ height: 24 }} />
      <Pressable onPress={() => void refresh()}>
        <Text style={{ color: theme.textMuted, fontSize: 11, textAlign: 'center' }}>
          {card.id}
        </Text>
      </Pressable>
    </Screen>
  );
}

function StepEditor({ steps, onChange }: { steps: StepItem[]; onChange: (s: StepItem[]) => void }) {
  const theme = useTheme();
  const update = (i: number, next: Partial<StepItem>) =>
    onChange(steps.map((s, idx) => (idx === i ? { ...s, ...next } : s)));
  const move = (i: number, delta: number) => {
    const j = i + delta;
    if (j < 0 || j >= steps.length) return;
    const copy = [...steps];
    [copy[i], copy[j]] = [copy[j], copy[i]];
    onChange(copy);
  };

  return (
    <View style={{ gap: Spacing.two }}>
      {steps.map((s, i) => (
        <View key={`${i}-${s.text}`} style={styles.stepRow}>
          <Pressable onPress={() => update(i, { done: !s.done })}>
            <Text style={{ fontSize: 16, color: s.done ? theme.success : theme.textMuted }}>
              {s.done ? '☑' : '☐'}
            </Text>
          </Pressable>
          <Text
            style={{
              flex: 1,
              color: theme.text,
              textDecorationLine: s.done ? 'line-through' : 'none',
            }}>
            {s.text}
          </Text>
          <Pressable onPress={() => move(i, -1)}>
            <Text style={{ color: theme.textMuted }}>↑</Text>
          </Pressable>
          <Pressable onPress={() => move(i, 1)}>
            <Text style={{ color: theme.textMuted }}>↓</Text>
          </Pressable>
        </View>
      ))}
      <Button
        title="＋ 添加一步"
        variant="ghost"
        compact
        onPress={() => onChange([...steps, { text: `第 ${steps.length + 1} 步`, done: false }])}
      />
    </View>
  );
}

function LocationPickerModal({
  visible,
  locations,
  onClose,
  onPick,
}: {
  visible: boolean;
  locations: LocationNode[];
  onClose: () => void;
  onPick: (ids: string[], names: string) => void;
}) {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const byId = useMemo(() => new Map(locations.map((l) => [l.id, l])), [locations]);

  const pathOf = (node: LocationNode) => {
    const ids: string[] = [];
    const names: string[] = [];
    let cur: LocationNode | undefined = node;
    while (cur) {
      ids.unshift(cur.id);
      names.unshift(cur.name);
      cur = cur.parentId ? byId.get(cur.parentId) : undefined;
    }
    return { ids, names: names.join('/') };
  };

  const depth = (node: LocationNode) => pathOf(node).ids.length;

  // 守卫不能省：这个组件是被无条件渲染的（<LocationPickerModal visible={pickerOpen}>），
  // 真正决定显隐的是下面 Modal 的 visible 属性。CameraModal 同样有这道守卫。
  if (!visible) return null;

  return (
    // ⚠️ 必须写 visible={visible}，绝不能写成布尔简写 `<Modal visible ...>` ——
    // 那是 visible={true}，弹窗会从进入页面起永久盖在最上层：视觉上一切正常，
    // 但全屏触摸都被它接住，关闭按钮与返回手势全部失效，用户只能杀进程。
    <Modal visible={visible} animationType="slide" onRequestClose={onClose}>
      <View style={{ flex: 1, backgroundColor: theme.background }}>
        {/*
          顶部安全区必须手动补：Android 开了边到边（gradle.properties edgeToEdgeEnabled=true），
          RN 的 Modal 是独立窗口、也会从 y=0 开始画，标题和「关闭」会落进状态栏底下。
          CameraModal 是同一个坑，那边已经这么补了。
        */}
        <View
          style={[
            styles.modalHeader,
            { borderColor: theme.border, paddingTop: insets.top + Spacing.two },
          ]}>
          <Text style={{ color: theme.text, fontSize: 16, fontWeight: '600' }}>选择位置</Text>
          <Button title="关闭" variant="ghost" compact onPress={onClose} />
        </View>
        <ScrollView
          contentContainerStyle={{
            padding: Spacing.three,
            gap: Spacing.one,
            paddingBottom: Spacing.three + insets.bottom,
          }}>
          {locations.length === 0 ? (
            <Text style={{ color: theme.textSecondary }}>
              还没有位置。解析卡片时会自动创建；也可以先去「设置 → 位置树」手动加一个。
            </Text>
          ) : (
            locations.map((l) => {
              const path = pathOf(l);
              return (
                <Pressable
                  key={l.id}
                  onPress={() => onPick(path.ids, path.names)}
                  style={({ pressed }) => [
                    styles.locationRow,
                    { paddingLeft: Spacing.three + (depth(l) - 1) * 16, opacity: pressed ? 0.6 : 1 },
                  ]}>
                  <Text style={{ color: theme.text, fontSize: 14 }}>
                    {depth(l) === 1 ? '🏠 ' : '· '}
                    {l.name}
                  </Text>
                  <Text style={{ color: theme.textMuted, fontSize: 11 }}>{path.names}</Text>
                </Pressable>
              );
            })
          )}
        </ScrollView>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  headerRow: { flexDirection: 'row', alignItems: 'flex-start' },
  title: { fontSize: 18, fontWeight: '700', flex: 1 },
  badges: { flexDirection: 'row', flexWrap: 'wrap', gap: 4 },
  row: { flexDirection: 'row', flexWrap: 'wrap', gap: 6 },
  stepRow: { flexDirection: 'row', alignItems: 'center', gap: Spacing.two },
  audioRow: { flexDirection: 'row', alignItems: 'center', gap: Spacing.two },
  photoStrip: { gap: Spacing.two, paddingVertical: 2 },
  photo: { width: 132, height: 132, borderRadius: Radius.sm },
  collapseHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: 2,
  },
  modalHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    padding: Spacing.three,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  locationRow: { paddingVertical: 10, gap: 2 },
});
