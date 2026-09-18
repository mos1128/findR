import { useCallback, useEffect, useRef, useState } from 'react';
import { ActivityIndicator, AppState, Pressable, StyleSheet, Text, TextInput, View } from 'react-native';
import { useFocusEffect, useRouter } from 'expo-router';
import { listCards, listCategories, type AnswerResult, type Category, type MemoryCard } from '@findr/core';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useNetworkState } from 'expo-network';

import { Radius, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { CardRow } from '@/ui/CardRow';
import { Button, Chip, EmptyState } from '@/ui/kit';
import { runAnswer, runQueueNow, runSearch, useRuntime, visionSupported } from '@/platform/runtime';
import { useLongPressRecorder } from '@/capture/recorder';
import { persistCapture } from '@/capture/submit';

export default function MemoryStreamScreen() {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const router = useRouter();
  const { state: rt, error: runtimeError } = useRuntime();
  const network = useNetworkState();
  const recorder = useLongPressRecorder();

  const [cards, setCards] = useState<MemoryCard[]>([]);
  const [categories, setCategories] = useState<Category[]>([]);
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<MemoryCard[] | null>(null);
  const [answer, setAnswer] = useState<AnswerResult | null>(null);
  const [answering, setAnswering] = useState(false);
  const [categoryFilter, setCategoryFilter] = useState<string | null>(null);
  const [searching, setSearching] = useState(false);
  const [busy, setBusy] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  const queueRunning = useRef(false);

  const reload = useCallback(() => {
    if (!rt) return;
    try {
      setCards(listCards(rt.driver, { categoryId: categoryFilter, limit: 100 }));
      setCategories(listCategories(rt.driver));
      setLoadError(null);
    } catch (e) {
      // 查询失败时不要把整块屏炸掉——自检期间这类错误必须看得见才有意义
      setLoadError(e instanceof Error ? e.message : String(e));
    }
  }, [rt, categoryFilter]);

  // 从录入/详情页返回时刷新，保证刚记的卡立刻出现在流里
  useFocusEffect(
    useCallback(() => {
      reload();
    }, [reload]),
  );

  /** 触发点之一：App 回前台补跑队列（技术设计五） */
  const drainQueue = useCallback(async () => {
    if (!rt || queueRunning.current) return;
    queueRunning.current = true;
    try {
      await runQueueNow(rt);
      reload();
    } finally {
      queueRunning.current = false;
    }
  }, [rt, reload]);

  useEffect(() => {
    const sub = AppState.addEventListener('change', (next) => {
      if (next === 'active') void drainQueue();
    });
    return () => sub.remove();
  }, [drainQueue]);

  const onSearch = async () => {
    if (!rt || !query.trim()) return;
    const q = query.trim();
    setSearching(true);
    setAnswer(null);
    try {
      const res = await runSearch(rt, q);
      setResults(res.cards);
      // 需求 5.3：本地无结果时自动组织一次答案，让模型说明「没找到 + 还缺什么线索」
      if (res.cards.length === 0) void requestAnswer(q, []);
    } catch {
      setResults([]);
    } finally {
      setSearching(false);
    }
  };

  /** 需求 5.3：L2 只在无结果或用户手动触发时跑，不是每次搜索都跑 */
  const requestAnswer = async (q: string, cards: MemoryCard[]) => {
    if (!rt) return;
    setAnswering(true);
    try {
      const res = await runAnswer(rt, q, cards);
      setAnswer(res.ok ? res : { ...res, answer: res.error ?? '总结失败' });
    } finally {
      setAnswering(false);
    }
  };

  /** 底部栏的长按语音：按下录、松开落盘并建卡 */
  const onVoicePressIn = async () => {
    setBusy(true);
    try {
      await recorder.start();
    } catch {
      setBusy(false);
    }
  };

  const onVoicePressOut = async () => {
    try {
      const audio = await recorder.stop();
      if (!audio || !rt) return;
      const draft = await persistCapture(rt, { images: [], audioUri: audio.uri, vision: false });
      reload();
      void draft;
      // 落盘后立刻推一次；失败了也还有队列在回前台时兜底
      await drainQueue();
    } finally {
      setBusy(false);
    }
  };

  const ctx = {
    visionSupported: visionSupported(rt?.llm ?? null),
    asrConfigured: !!rt?.asr,
  };
  const categoryName = (id: string | null) =>
    id ? (categories.find((c) => c.id === id)?.name ?? null) : null;

  const offline = network.isConnected === false;
  const noAsr = !rt?.asr;

  return (
    <View style={[styles.root, { backgroundColor: theme.background }]}>
      {/* 顶部：查。与底部「记」刻意做成两种材质，避免误用（需求六） */}
      <View style={[styles.topBar, { backgroundColor: theme.searchSurface, borderColor: theme.border }]}>
        <View style={[styles.searchRow, { borderColor: theme.border, backgroundColor: theme.surfaceAlt }]}>
          <Text style={{ color: theme.search, fontSize: 14 }}>🔍</Text>
          <TextInput
            value={query}
            onChangeText={setQuery}
            onSubmitEditing={onSearch}
            returnKeyType="search"
            placeholder="问一句，比如「护照放哪了」"
            placeholderTextColor={theme.textMuted}
            style={[styles.searchInput, { color: theme.text }]}
          />
          {query ? (
            <Pressable
              onPress={() => {
                setQuery('');
                setResults(null);
                setAnswer(null);
              }}>
              <Text style={{ color: theme.textMuted, fontSize: 14 }}>✕</Text>
            </Pressable>
          ) : null}
        </View>

        <View style={styles.chips}>
          <Chip label="全部" active={categoryFilter === null} onPress={() => setCategoryFilter(null)} />
          {categories.map((c) => (
            <Chip
              key={c.id}
              label={`${c.emoji ?? ''}${c.name}`}
              active={categoryFilter === c.id}
              onPress={() => setCategoryFilter(categoryFilter === c.id ? null : c.id)}
            />
          ))}
          <Chip label="➕ 新建分类" onPress={() => router.push('/settings/categories')} />
        </View>
      </View>

      <View style={styles.list}>
        {/* 数据库都没打开的话，其余界面全是空转；必须让用户看得见原因，
            否则只会看到一片空白，而自检入口还在设置里根本走不到 */}
        {runtimeError || loadError ? (
          <View style={[styles.fatal, { backgroundColor: theme.badgeOrganizeBg, borderColor: theme.danger }]}>
            <Text style={{ color: theme.danger, fontWeight: '700', fontSize: 14 }}>
              {runtimeError ? '数据库没能打开' : '读取卡片失败'}
            </Text>
            <Text style={{ color: theme.textSecondary, fontSize: 12, lineHeight: 17 }}>
              {runtimeError ?? loadError}
            </Text>
          </View>
        ) : null}

        {searching ? <ActivityIndicator color={theme.record} style={{ marginTop: Spacing.three }} /> : null}

        {results ? (
          <View style={styles.resultsHeader}>
            <Text style={[styles.resultsLabel, { color: theme.textSecondary }]}>
              检索结果 {results.length} 条
            </Text>
            <View style={styles.headerActions}>
              {results.length > 0 && !answer ? (
                <Button
                  title="AI 总结"
                  variant="ghost"
                  compact
                  loading={answering}
                  onPress={() => void requestAnswer(query.trim(), results)}
                />
              ) : null}
              <Button
                title="回到记忆流"
                variant="ghost"
                compact
                onPress={() => {
                  setResults(null);
                  setAnswer(null);
                }}
              />
            </View>
          </View>
        ) : null}

        {/* 需求六：搜索时 AI 答案卡片置顶高亮 */}
        {answer ? (
          <View style={[styles.answerCard, { backgroundColor: theme.surface, borderColor: theme.record }]}>
            <Text style={[styles.answerTag, { color: theme.record }]}>AI 答案</Text>
            <Text style={{ color: theme.text, fontSize: 15, lineHeight: 22 }}>{answer.answer}</Text>
            {answer.suggest ? (
              <Text style={{ color: theme.textSecondary, fontSize: 12, lineHeight: 17 }}>
                {answer.suggest}
              </Text>
            ) : null}
            {answer.hitIds.length > 0 ? (
              <Text style={{ color: theme.textMuted, fontSize: 11 }}>
                依据 {answer.hitIds.length} 张卡片，已在下面高亮
              </Text>
            ) : null}
          </View>
        ) : null}

        <View style={styles.cards}>
          {(results ?? cards).map((card) => (
            <CardRow
              key={card.id}
              card={card}
              ctx={ctx}
              categoryName={categoryName(card.categoryId)}
              highlight={answer?.hitIds.includes(card.id) ?? false}
              onPress={() => router.push(`/card/${card.id}`)}
            />
          ))}
        </View>

        {!searching && (results ?? cards).length === 0 ? (
          <EmptyState
            title={results ? '没找到相关记忆' : '还没有记忆'}
            hint={
              results
                ? '换个说法试试，或者先看看底部怎么记一笔'
                : '用底部的相机、键盘或长按麦克风记下第一笔'
            }
          />
        ) : null}

        {/* 需求 3.2：无网时先提示「先拍照，稍后补一句」，而不是让用户说完才发现转写不了 */}
        {offline || noAsr ? (
          <View style={[styles.notice, { backgroundColor: theme.badgeConfirmBg }]}>
            <Text style={[styles.noticeText, { color: theme.badgeConfirm }]}>
              {offline
                ? '当前无网络：先拍照或打字，稍后联网会自动补上解析。'
                : '还没配置 ASR：语音会先存着，之后补一句话就能解析。'}
            </Text>
          </View>
        ) : null}
      </View>

      {/* 底部：记 */}
      <View
        style={[
          styles.bottomBar,
          { backgroundColor: theme.surface, borderColor: theme.border, paddingBottom: insets.bottom + 8 },
        ]}>
        <Pressable
          onPress={() => router.push('/capture?mode=photo')}
          style={({ pressed }) => [styles.toolButton, { opacity: pressed ? 0.6 : 1 }]}>
          <Text style={styles.toolEmoji}>📷</Text>
        </Pressable>
        <Pressable
          onPress={() => router.push('/capture?mode=text')}
          style={({ pressed }) => [styles.toolButton, { opacity: pressed ? 0.6 : 1 }]}>
          <Text style={styles.toolEmoji}>⌨️</Text>
        </Pressable>

        <Pressable
          onPressIn={() => void onVoicePressIn()}
          onPressOut={() => void onVoicePressOut()}
          disabled={busy && !recorder.isRecording}
          style={[
            styles.voiceButton,
            { backgroundColor: recorder.isRecording ? theme.danger : theme.record },
          ]}>
          <Text style={styles.voiceLabel}>
            {recorder.isRecording
              ? `● ${Math.round(recorder.durationMs / 1000)}s 松开结束`
              : '🎙️ 长按说话'}
          </Text>
        </Pressable>

        <Pressable
          onPress={() => router.push('/settings')}
          style={({ pressed }) => [styles.toolButton, { opacity: pressed ? 0.6 : 1 }]}>
          <Text style={styles.toolEmoji}>⚙️</Text>
        </Pressable>
      </View>

      {recorder.isRecording ? (
        <View style={[styles.recordingOverlay, { backgroundColor: theme.surface, borderColor: theme.border }]}>
          <Text style={{ color: theme.danger, fontWeight: '600' }}>
            ● 录音中 {Math.round(recorder.durationMs / 1000)}s
          </Text>
          <Text style={{ color: theme.textSecondary, fontSize: 12 }}>松开手指结束</Text>
        </View>
      ) : null}

      {rt && !rt.llm ? (
        <Pressable
          onPress={() => router.push('/settings/provider')}
          style={[styles.setupHint, { backgroundColor: theme.badgeConfirmBg }]}>
          <Text style={{ color: theme.badgeConfirm, fontSize: 13 }}>
            还没配置主模型，点这里去填写 →
          </Text>
        </Pressable>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  topBar: {
    paddingHorizontal: Spacing.three,
    paddingTop: Spacing.two,
    paddingBottom: Spacing.two,
    gap: Spacing.two,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  searchRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.two,
    borderRadius: Radius.pill,
    borderWidth: StyleSheet.hairlineWidth,
    paddingHorizontal: Spacing.three,
    paddingVertical: 8,
  },
  searchInput: { flex: 1, fontSize: 15, padding: 0 },
  chips: { flexDirection: 'row', gap: 6, flexWrap: 'wrap' },
  list: { flex: 1, padding: Spacing.three, gap: Spacing.two },
  cards: { gap: Spacing.two },
  resultsHeader: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  headerActions: { flexDirection: 'row', gap: Spacing.one, alignItems: 'center' },
  resultsLabel: { fontSize: 13, fontWeight: '600' },
  answerCard: {
    borderRadius: Radius.md,
    borderWidth: 1.5,
    padding: Spacing.three,
    gap: Spacing.two,
  },
  answerTag: { fontSize: 11, fontWeight: '700', letterSpacing: 0.5 },
  fatal: {
    borderRadius: Radius.md,
    borderWidth: 1,
    padding: Spacing.three,
    gap: Spacing.two,
  },
  notice: { borderRadius: Radius.md, padding: Spacing.three },
  noticeText: { fontSize: 12, lineHeight: 17 },
  bottomBar: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.two,
    paddingHorizontal: Spacing.three,
    paddingTop: Spacing.two,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  toolButton: {
    width: 44,
    height: 44,
    alignItems: 'center',
    justifyContent: 'center',
  },
  toolEmoji: { fontSize: 20 },
  voiceButton: {
    flex: 1,
    borderRadius: Radius.pill,
    paddingVertical: 12,
    alignItems: 'center',
  },
  voiceLabel: { color: '#ffffff', fontSize: 15, fontWeight: '600' },
  recordingOverlay: {
    position: 'absolute',
    left: Spacing.three,
    right: Spacing.three,
    bottom: 96,
    borderRadius: Radius.md,
    borderWidth: StyleSheet.hairlineWidth,
    padding: Spacing.three,
    alignItems: 'center',
    gap: 4,
  },
  setupHint: {
    position: 'absolute',
    left: Spacing.three,
    right: Spacing.three,
    top: 8,
    borderRadius: Radius.md,
    padding: Spacing.three,
    alignItems: 'center',
  },
});
