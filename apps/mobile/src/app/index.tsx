import { useCallback, useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  AppState,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { useFocusEffect, useRouter } from 'expo-router';
import {
  listCards,
  listCategories,
  type AdviceResult,
  type AnswerResult,
  type Category,
  type MemoryCard,
} from '@findr/core';
import { useNetworkState } from 'expo-network';

import { Radius, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { CardRow } from '@/ui/CardRow';
import { Button, Chip, EmptyState } from '@/ui/kit';
import {
  llmConfigured,
  runAnswer,
  runQueueNow,
  runSearch,
  useRuntime,
  visionSupported,
} from '@/platform/runtime';
import { Composer } from '@/capture/Composer';

export default function MemoryStreamScreen() {
  const theme = useTheme();
  const router = useRouter();
  const { state: rt, error: runtimeError, refresh } = useRuntime();
  const network = useNetworkState();

  const [cards, setCards] = useState<MemoryCard[]>([]);
  const [categories, setCategories] = useState<Category[]>([]);
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<MemoryCard[] | null>(null);
  const [answer, setAnswer] = useState<AnswerResult | null>(null);
  /**
   * 答案没生成出来时的原因。**刻意与 `answer` 分开**：
   * 以前是把错误文本塞进 `answer.answer`，于是界面用同样的「AI 答案」样式把一句
   * 报错当答案读给用户听；而且 `answer` 一旦非空，「AI 总结」按钮就消失了 ——
   * 失败之后连重试都没得点。分开之后：失败不占答案位、按钮还在、提示语也说得清。
   */
  const [answerError, setAnswerError] = useState<string | null>(null);
  /**
   * 推理题（advise）的裁决结果。与 `answer` 是两条互斥的路：
   * 定位题的答案是「复述已找到的片段」，推理题的答案本身就是「挑哪些、还缺什么」，
   * 两者的呈现方式不同，所以不共用一个 state。
   */
  const [advice, setAdvice] = useState<AdviceResult | null>(null);
  const [answering, setAnswering] = useState(false);
  /** 本次检索实际走了哪条路（未配模型 / 模型不可达 / 意图不明）—— 空结果时必须说清原因 */
  const [searchNote, setSearchNote] = useState<string | null>(null);
  const [categoryFilter, setCategoryFilter] = useState<string | null>(null);
  const [searching, setSearching] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  const queueRunning = useRef(false);
  /** 有可用的主模型配置（模型名 + 可选地址；API Key 不参与判定）—— 决定检索走哪条路 */
  const llmReady = llmConfigured(rt?.llm ?? null);
  /** 每次搜索都自动组织答案（设置页开关，默认关）。开了也**不阻塞列表** —— 见 onSearch */
  const autoAnswer = rt?.search.autoAnswer ?? false;

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
    setAnswerError(null);
    setAdvice(null);
    try {
      const res = await runSearch(rt, q);
      setResults(res.cards);
      setAdvice(res.advice ?? null);
      // 没配模型时检索**照样能用**（字面兜底），但结果比有模型时弱，
      // 空结果尤其容易被误读成「卡片丢了」—— 所以必须说清走的是哪条路。
      // 推理题（advice）走的是另一条路，提示语也得另给：
      // usedFallback 在这里的意思是「模型没挑出直接相关的，下面是字面命中的」，
      // 不是「模型不可达」—— 用下面那句成辞会冤枉模型。
      if (res.advice) {
        setSearchNote(
          res.usedFallback
            ? '模型没从库里挑出直接相关的东西，下面是字面命中的条目，供你参考。'
            : null,
        );
      } else if (res.relaxed) {
        // 靠放宽条件才拿到的结果必须说清 —— 否则用户会把这批宽结果当成严格匹配
        setSearchNote('模型给的条件太严（分类 / 时间 / 位置，或要求全词命中），已放宽后匹配到以下结果。');
      } else if (res.unclear) {
        setSearchNote(
          res.cards.length > 0
            ? '模型没听懂这句话，已退化为按关键词字面检索，结果可能不全。'
            : '模型没听懂这句话，换个说法试试。',
        );
      } else if (res.usedFallback) {
        setSearchNote(
          llmReady
            ? '模型当前不可达，已退化为按关键词字面检索（没有同义词扩展与分类/位置约束）。'
            : '还没配置模型，按关键词字面检索。多个关键词用空格分开会更准。',
        );
      } else {
        setSearchNote(null);
      }
      // 需求 5.3：本地无结果时自动组织一次答案。没有模型就别触发 —— 那必然是一次失败请求。
      // 第十四版：开了「每次搜索都自动组织答案」时，有结果也自动跑。
      // 这里**刻意不 await** —— 列表上面已经 setResults 了，答案回来再追加到列表下方，
      // 所以多出来的那一次调用不会让列表晚出现一毫秒（渐进式）。
      //
      // 推理题（res.advice）不走这一步：它的答案就是那次裁决本身，
      // 再跑一次 L2 只会把同一批卡片复述一遍，白花一次调用。
      if (llmReady && !res.advice && (res.cards.length === 0 || autoAnswer)) {
        void requestAnswer(q, res.cards);
      }
    } catch (e) {
      setResults([]);
      setSearchNote(e instanceof Error ? e.message : '检索失败');
    } finally {
      setSearching(false);
    }
  };

  /** 需求 5.3：L2 只在无结果或用户手动触发时跑，不是每次搜索都跑 */
  const requestAnswer = async (q: string, cards: MemoryCard[]) => {
    if (!rt) return;
    setAnswering(true);
    setAnswerError(null);
    try {
      const res = await runAnswer(rt, q, cards);
      if (res.ok) {
        setAnswer(res);
      } else {
        // 真的没总结出内容 ≠ 总结失败：报错不占答案位，按钮留着让人重试
        setAnswerError(res.error ?? '模型没有返回可用的内容。');
      }
    } catch (e) {
      // 未配模型时 requireDeps 会抛 —— 这里必须接住，否则是一次未处理的 Promise 拒绝
      setAnswerError(e instanceof Error ? e.message : String(e));
    } finally {
      setAnswering(false);
    }
  };

  /**
   * 底部录入条存下一条之后：刷新记忆流并推进解析队列。
   *
   * `vision` 必须**原样**传进队列，同时再把运行时重新读一遍 ——
   * `rt.capture` 是打开时的快照，用户刚在录入条上关掉图片分析时它还是旧值；
   * 不重读的话，回前台的队列会拿旧值处理这张卡（用户关了开关却仍然外发图片）。
   * 重读之后 `rt` 变了，`drainQueue` 与挂在 AppState 上的监听也一起换到新值。
   */
  const afterSubmit = useCallback(
    async (vision: boolean) => {
      reload();
      const next = await refresh();
      if (next) await runQueueNow(next, { vision });
      reload();
    },
    [reload, refresh],
  );

  const ctx = {
    visionSupported: visionSupported(rt?.llm ?? null),
    asrConfigured: !!rt?.asr,
  };
  const categoryName = (id: string | null) =>
    id ? (categories.find((c) => c.id === id)?.name ?? null) : null;
  const categoryEmoji = (id: string | null) =>
    id ? (categories.find((c) => c.id === id)?.emoji ?? null) : null;

  const offline = network.isConnected === false;
  const noAsr = !rt?.asr;

  /**
   * 建议型结果里每张卡的入选理由（advise 专有）。
   *
   * 必须给理由：这类结果不是字面命中，是模型挑出来的 —— 不给理由，用户无从判断该不该信。
   * 「看情况」那一档尤其要带上前缀，否则它和「必需」在列表里长得一模一样。
   */
  const adviceNote = (a: AdviceResult | null, cardId: string): string | undefined => {
    if (!a) return undefined;
    const pick = a.picks.find((p) => p.id === cardId);
    if (pick) return pick.why || undefined;
    const maybe = a.maybe.find((m) => m.id === cardId);
    if (maybe) return `看情况：${maybe.why || '取决于你的具体情况'}`;
    return undefined;
  };

  return (
    <View style={[styles.root, { backgroundColor: theme.background }]}>
      {/* 顶部：查。与底部「记」刻意做成两种材质，避免误用（需求六） */}
      <View style={[styles.topBar, { backgroundColor: theme.searchSurface, borderColor: theme.border }]}>
        {/* 设置入口跟搜索框同行。它原先挤在底部那一排按钮里；底部收成一条输入条之后，
            那里只该放「记」，设置挪到这里既腾出了位置，也不再和「记」抢注意力 */}
        <View style={styles.searchLine}>
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
                  setAnswerError(null);
                  setAdvice(null);
                }}>
                <Text style={{ color: theme.textMuted, fontSize: 14 }}>✕</Text>
              </Pressable>
            ) : null}
          </View>

          <Pressable
            onPress={() => router.push('/settings')}
            style={({ pressed }) => [styles.gear, { opacity: pressed ? 0.6 : 1 }]}>
            <Text style={{ fontSize: 18 }}>⚙️</Text>
          </Pressable>
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

        {/*
          这里以前是一个 `position:'absolute', top:8` 的浮层，正好压在上面的搜索框（y≈8~42）上。
          它只在「未配模型」时显示，而多数用户一开始都没配模型 ⇒ 搜索框被永久遮住，
          表现为「找不到搜索入口」（真机反馈）。
          改成正常文档流里的一行：既不会被任何东西盖住，也不必滚到列表底部才看见。
          文案里带上「点这里」，代替原来的浮层按钮。
        */}
        {!llmReady ? (
          <Pressable
            onPress={() => router.push('/settings/provider')}
            style={({ pressed }) => [
              styles.topHint,
              { backgroundColor: theme.badgeConfirmBg, opacity: pressed ? 0.75 : 1 },
            ]}>
            <Text style={{ color: theme.badgeConfirm, fontSize: 12, lineHeight: 17 }}>
              还没配置模型：内容都留在本地，随时能翻找和编辑。点这里填写 →
            </Text>
          </Pressable>
        ) : null}
      </View>

      {/*
        记忆流必须是滚动容器：这里以前是一个普通 <View style={styles.list}>，
        既没有 ScrollView 也没有 FlatList，卡片一多就只是「被下边缘挡住」而划不动
        （真机反馈：首页列表划不动）。注意 padding/gap 要放在 contentContainerStyle 上
        —— 放在 style 上会把内容区压掉一圈，滚动时首尾卡片会贴边。
      */}
      <ScrollView
        style={styles.list}
        contentContainerStyle={styles.listContent}
        keyboardShouldPersistTaps="handled">
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
              {advice ? `为你挑出 ${results.length} 条` : `检索结果 ${results.length} 条`}
            </Text>
            <View style={styles.headerActions}>
              {/* 没有模型时不给「AI 总结」入口 —— 点了必然失败。
                  组织过程中收起按钮，改由列表下方那行「正在组织答案…」提示，
                  否则同屏会出现两个指示器（按钮转圈 + 底部一行字）。
                  建议型结果也不给：那一屏的答案就是裁决本身，再总结一次是重复劳动 */}
              {results.length > 0 && !answer && !advice && !answering && llmReady ? (
                <Button
                  title="AI 总结"
                  variant="ghost"
                  compact
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
                  setAnswerError(null);
                  setAdvice(null);
                }}
              />
            </View>
          </View>
        ) : null}

        {/* 走的是哪条检索路必须说清楚：没配模型 / 模型不可达时结果会明显变弱，
            不说的话用户会把「字面没搜到」误读成「卡片丢了」 */}
        {results && searchNote ? (
          <View style={[styles.notice, { backgroundColor: theme.surfaceAlt }]}>
            <Text style={[styles.noticeText, { color: theme.textSecondary }]}>{searchNote}</Text>
          </View>
        ) : null}

        <View style={styles.cards}>
          {(results ?? cards).map((card) => (
            <CardRow
              key={card.id}
              card={card}
              ctx={ctx}
              categoryName={categoryName(card.categoryId)}
              categoryEmoji={categoryEmoji(card.categoryId)}
              highlight={answer?.hitIds.includes(card.id) ?? false}
              note={adviceNote(advice, card.id)}
              onPress={() => router.push(`/card/${card.id}`)}
            />
          ))}
        </View>

        {/* 第十四版：AI 答案**追加在列表下方**，不再置顶（原「需求六 · 置顶高亮」据此改）。
            理由是渐进式：答案要晚一两秒才回来，置顶会把已经读着的列表整块推下去，形成跳动；
            追加在下方则列表纹丝不动，答案自己在下面长出来。 */}
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
                依据 {answer.hitIds.length} 张卡片，已在上方高亮
              </Text>
            ) : null}
          </View>
        ) : null}

        {/* 推理题（advise）的建议卡：位置与 AI 答案一致（列表下方），但内容不同 ——
            它给的不是「复述已找到的东西」，而是「挑哪些、还缺什么」。 */}
        {advice ? (
          <View style={[styles.answerCard, { backgroundColor: theme.surface, borderColor: theme.record }]}>
            <Text style={[styles.answerTag, { color: theme.record }]}>AI 建议</Text>
            <Text style={{ color: theme.text, fontSize: 15, lineHeight: 22 }}>{advice.answer}</Text>
            {advice.missing.length > 0 ? (
              <Text style={{ color: theme.badgeConfirm, fontSize: 13, lineHeight: 19 }}>
                库里还没有：{advice.missing.join('、')}
              </Text>
            ) : null}
            <Text style={{ color: theme.textMuted, fontSize: 11 }}>
              必需 {advice.picks.length} 项
              {advice.maybe.length > 0 ? ` · 看情况 ${advice.maybe.length} 项` : ''}
            </Text>
          </View>
        ) : null}

        {/* 渐进式的唯一指示器：列表已经能用，答案还在路上。刻意放在答案即将出现的位置 */}
        {answering && !answer && results ? (
          <View style={[styles.notice, { backgroundColor: theme.surfaceAlt }]}>
            <Text style={[styles.noticeText, { color: theme.textSecondary }]}>正在组织答案…</Text>
          </View>
        ) : null}

        {/* 答案没生成出来。刻意**不占「AI 答案」那个位置**、也不盖掉空态：
            列表本身是好的，这只是一次附加调用没跑成 —— 说清原因、把按钮留着让人重试就够。
            以前这里是把错误文本当答案显示，读起来像模型在胡说。 */}
        {answerError && !answering ? (
          <View style={[styles.notice, { backgroundColor: theme.surfaceAlt }]}>
            <Text style={[styles.noticeText, { color: theme.textSecondary }]}>
              没能组织答案：{answerError}
            </Text>
            <Text style={{ color: theme.textMuted, fontSize: 11, lineHeight: 16, marginTop: 4 }}>
              {results && results.length > 0
                ? '卡片列表不受影响，可以点「AI 总结」重试。'
                : '可以点「AI 总结」重试，或换个说法再搜一次。'}
            </Text>
          </View>
        ) : null}

        {/* 空态。正在组织答案时先不喊「没找到」—— 否则会先闪一句空话，再被答案推翻。
            建议型结果也一样：卡片可能一条都没挑出来（库里确实没有合适的），
            但那一屏有价值的是「你还缺什么」，不能被一句空态盖掉 */}
        {!searching && !answer && !advice && !answering && (results ?? cards).length === 0 ? (
          <EmptyState
            title={results ? '没找到相关记忆' : '还没有记忆'}
            hint={
              results
                ? llmReady
                  ? '换个说法试试，或者先看看底部怎么记一笔'
                  : '当前没有可用模型，只做了关键词字面匹配。试试更具体的词，或把几个关键词用空格分开，比如「护照 柜子」。'
                : '用底部的相机、键盘或长按麦克风记下第一笔'
            }
          />
        ) : null}

        {/* 需求 3.2：无网时先提示「先拍照，稍后补一句」，而不是让用户说完才发现转写不了。
            「没配模型」那一种已在顶部提示条里说明，这里不重复，否则同一屏会出现两段几乎一样的话 */}
        {offline || noAsr ? (
          <View style={[styles.notice, { backgroundColor: theme.badgeConfirmBg }]}>
            <Text style={[styles.noticeText, { color: theme.badgeConfirm }]}>
              {offline
                ? '当前无网络：先拍照或打字，稍后联网会自动补上解析。'
                : '还没配置 ASR：语音会先存着，之后补一句话就能解析。'}
            </Text>
          </View>
        ) : null}
      </ScrollView>

      {/* 底部：记。**唯一**的录入入口 —— 打字 / 拍照 / 相册 / 文本文件 / 长按语音
          全在这一条里，不再有「两个按钮通到同一个页面」那种事（见 capture/Composer.tsx） */}
      <Composer rt={rt} onSubmitted={afterSubmit} />
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
  searchLine: { flexDirection: 'row', alignItems: 'center', gap: Spacing.two },
  searchRow: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.two,
    borderRadius: Radius.pill,
    borderWidth: StyleSheet.hairlineWidth,
    paddingHorizontal: Spacing.three,
    paddingVertical: 8,
  },
  gear: { width: 40, height: 40, alignItems: 'center', justifyContent: 'center' },
  searchInput: { flex: 1, fontSize: 15, padding: 0 },
  chips: { flexDirection: 'row', gap: 6, flexWrap: 'wrap' },
  /** 滚动容器本体只管占满剩余高度，内边距与间距全交给 contentContainerStyle */
  list: { flex: 1 },
  listContent: { padding: Spacing.three, gap: Spacing.two, paddingBottom: Spacing.four },
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
  /**
   * 「未配模型」提示条：必须在正常文档流里。
   * 曾经写成 `position:'absolute', top:8`，正好盖住上面的搜索框 —— 别再改回浮层。
   */
  topHint: {
    borderRadius: Radius.md,
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.two,
  },
});
