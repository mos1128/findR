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
import { useAudioPlayer, useAudioPlayerStatus } from 'expo-audio';
import {
  advanceCard,
  badgeLabel,
  canReanalyze,
  cardBadges,
  clearNeedsConfirm,
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
  type StructureType,
} from '@findr/core';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { Radius, Spacing, structureLabel } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { Badge, Button, Chip, Field, ListRow, Panel, Screen, SectionTitle } from '@/ui/kit';
import { mediaUri } from '@/platform/media';
import { currentVision, requireDeps, useRuntime, visionSupported } from '@/platform/runtime';

const STATUS_LABELS: Record<StructureType, { value: string[]; labels: string[] }> = {
  item: { value: ['in_stock', 'lent', 'used', 'discarded'], labels: ['在库', '借出', '已用', '已弃'] },
  todo: { value: ['open', 'done', 'dropped'], labels: ['待办', '已完成', '已放弃'] },
  procedure: { value: ['draft', 'ready'], labels: ['草稿', '可用'] },
};

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
  const statusMeta = card.structureType ? STATUS_LABELS[card.structureType] : null;
  const currentStatus =
    card.structureType === 'item'
      ? card.itemStatus
      : card.structureType === 'todo'
        ? card.todoStatus
        : card.procedureStatus;

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
      </Panel>

      {card.needsConfirm || card.retryCount > 0 || card.status === 'pending' || card.status === 'pending_transcript' || card.needsOrganize ? (
        <Panel>
          <SectionTitle hint="解决后角标即消失">待办</SectionTitle>
          {card.needsConfirm ? (
            <Button
              title="确认信息无误"
              variant="secondary"
              onPress={() => {
                clearNeedsConfirm(rt.driver, card.id, new Date());
                reload();
              }}
            />
          ) : null}
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

      {card.audioPath ? (
        <Panel>
          <SectionTitle>录音</SectionTitle>
          <Button
            title={playerStatus.playing ? '暂停' : '播放'}
            variant="secondary"
            onPress={() => (playerStatus.playing ? player.pause() : player.play())}
          />
          {card.status === 'pending_transcript' ? (
            <Text style={{ color: theme.textMuted, fontSize: 12 }}>
              还没有文字。在下面「口述原文」里补一句，卡片就能解析入库。
            </Text>
          ) : null}
        </Panel>
      ) : null}

      <Panel>
        <SectionTitle>结构类型</SectionTitle>
        <View style={styles.row}>
          {(['item', 'todo', 'procedure'] as StructureType[]).map((t) => (
            <Chip
              key={t}
              label={structureLabel[t]}
              active={card.structureType === t}
              onPress={() => patch({ structureType: t })}
            />
          ))}
        </View>

        <SectionTitle hint="AI 自动路由，可随时更正">分类</SectionTitle>
        <View style={styles.row}>
          {categories.map((c) => (
            <Chip
              key={c.id}
              label={`${c.emoji ?? ''}${c.name}`}
              active={card.categoryId === c.id}
              onPress={() => patch({ categoryId: c.id, structureType: c.structureType })}
            />
          ))}
        </View>

        {card.structureType === 'item' ? (
          <>
            <SectionTitle hint="仅物品类必填">位置</SectionTitle>
            {/*
              位置的来源已经变了：解析卡片时自动匹配/新建，用户来这里只是「看一眼、改一改」。
              旧文案写的是「从已有位置树里选」，配合一个空位置树，等于逼用户先去手工建房间。
            */}
            <ListRow
              title={card.pathNames ?? '还没记录位置'}
              subtitle={
                card.pathNames
                  ? card.pathMatched === false
                    ? '解析时新建的位置，不对可以改'
                    : '解析时自动记录；点这里可以改到别处'
                  : '解析这条卡片时会自动记录；也可以现在手动选一个'
              }
              onPress={() => setPickerOpen(true)}
              right={
                <Text style={{ color: theme.record }}>{card.pathNames ? '修改' : '选择'}</Text>
              }
            />
            {card.pathNames ? (
              <Button
                title="清除位置"
                variant="ghost"
                compact
                onPress={() => patch({ pathIds: null, pathNames: null })}
              />
            ) : null}
          </>
        ) : null}

        {statusMeta ? (
          <>
            <SectionTitle>业务状态</SectionTitle>
            <View style={styles.row}>
              {statusMeta.value.map((v, i) => (
                <Chip
                  key={v}
                  label={statusMeta.labels[i]}
                  active={currentStatus === v}
                  onPress={() => {
                    const key =
                      card.structureType === 'item'
                        ? 'itemStatus'
                        : card.structureType === 'todo'
                          ? 'todoStatus'
                          : 'procedureStatus';
                    patch({ [key]: v } as Parameters<typeof updateCardFields>[2]);
                  }}
                />
              ))}
            </View>
          </>
        ) : null}
      </Panel>

      <Panel>
        <SectionTitle hint="可编辑，改完可以重新生成描述">描述</SectionTitle>
        <Field label="desc" value={card.desc ?? ''} onChangeText={(v) => patch({ desc: v })} multiline />
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
        <Field
          label="口述原文"
          value={card.transcript ?? ''}
          onChangeText={(v) => patch({ transcript: v })}
          multiline
        />
        <Field
          label="关联人"
          value={card.relatedPerson ?? ''}
          onChangeText={(v) => patch({ relatedPerson: v })}
          placeholder="借给谁 / 帮谁买"
        />
        <Field
          label="到期或周期"
          value={card.dueAt ?? card.cycle ?? ''}
          onChangeText={(v) => patch({ dueAt: v || null })}
          placeholder="如 2026-04-01 或 半年一次"
        />
      </Panel>

      {card.structureType !== 'item' ? (
        <Panel>
          <SectionTitle hint="流程类必填；待办可选作子待办">步骤</SectionTitle>
          <StepEditor
            steps={card.steps ?? []}
            onChange={(steps) => patch({ steps: steps.length > 0 ? steps : null })}
          />
        </Panel>
      ) : null}

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
  modalHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    padding: Spacing.three,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  locationRow: { paddingVertical: 10, gap: 2 },
});
