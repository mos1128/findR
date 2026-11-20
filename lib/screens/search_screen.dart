/// 搜索页。
///
/// 从首页顶部的搜索框点进来。**单独一页是为了给最近搜索留位置**：
/// 首页那一屏已经被「查」「记」两条链路占满，再插一行历史就会把记忆流挤下去。
///
/// 四条口径：
///
/// 1. **检索状态仍然在 `memoryStreamProvider` 里**（首页也在用同一份），
///    所以退出这页时要把检索清掉，否则回到首页会看到「记忆流里混着上一次的检索结果」。
/// 2. **输入框在底部**，和录入条同一个位置：搜索也要说话，而举着手机去够屏幕顶是反手的。
///    进来就聚焦（那一下点击已经表达了「要打字」），不用再点一次输入框。
/// 3. **打字和说话是两种模式，不共用一颗按钮**：左边那颗切，中间那颗按，右边那颗搜 ——
///    和录入条从左到右是同一套手感。语音态才把长按交给 [HoldInput]，
///    打字态里一个手势都不抢（长按就是输入框自己的选词）。
///    按住就开麦、松手就停，没有「先按稳 200ms」那段白等。
/// 4. **分类筛选不在这页**：`searchCards` 没有分类参数，客户端再过滤一遍会被
///    「放宽条件」那套逻辑反复推翻，用户看到的是「筛了又没筛」。分类留在首页的记忆流上。
library;

import 'dart:async';
import 'dart:io';

import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../capture/record_alert.dart';
import '../capture/recorder.dart';
import '../platform/runtime.dart';
import '../state/memory_stream.dart';
import '../theme/tokens.dart';
import '../ui/card_row.dart';
import '../ui/dock.dart';
import '../ui/haptics.dart';
import '../ui/hold_input.dart';
import '../ui/kit.dart';
import 'card_detail_screen.dart';

/// 最近搜索最多留几条。再多就不叫「最近」了，横排两行也会撑爆。
const int recentSearchLimit = 8;

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _recorder = LongPressRecorder();

  List<String> _recent = const <String>[];

  /// 现在是「语音输入」那一侧。两种输入各占一种手势，谁也不兼着谁。
  bool _voice = false;

  bool _recording = false;
  bool _cancelArmed = false;
  bool _pressing = false;

  /// 正在把录音转成文字。这期间不接受新的长按。
  bool _transcribing = false;

  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _loadRecent();
    // 进这页就先清掉上一次的检索：否则「最近搜索」旁边会躺着上一轮的结果。
    // 必须等这一帧画完 —— 在 initState 里改 provider 会撞上「build 期间修改 provider」。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(memoryStreamProvider.notifier).clearSearch();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _focus.dispose();
    _controller.dispose();
    unawaited(_recorder.dispose());
    super.dispose();
  }

  /// 最近搜索只存在本机（`deviceLocalSettingKeys`），换机不跟着备份走。
  void _loadRecent() {
    final rt = ref.read(runtimeProvider).value;
    if (rt == null) return;
    final raw = getSetting<List<dynamic>>(rt.driver, kRecentSearchesKey);
    setState(() {
      _recent = <String>[
        for (final item in raw ?? const <dynamic>[])
          if (item is String && item.trim().isNotEmpty) item,
      ];
    });
  }

  void _remember(String query) {
    final rt = ref.read(runtimeProvider).value;
    final next = <String>[
      query,
      for (final item in _recent)
        if (item != query) item,
    ];
    final capped = next.take(recentSearchLimit).toList();
    setState(() => _recent = capped);
    if (rt != null) setSetting(rt.driver, kRecentSearchesKey, capped);
  }

  Future<void> _run(String raw) async {
    final q = raw.trim();
    if (q.isEmpty) return;
    if (_controller.text != q) {
      _controller.value = TextEditingValue(
        text: q,
        selection: TextSelection.collapsed(offset: q.length),
      );
    }
    _focus.unfocus();
    _remember(q);

    final notifier = ref.read(memoryStreamProvider.notifier);
    await notifier.search(q);
    final s = ref.read(memoryStreamProvider).value;
    final view = s?.search;
    if (s == null || view == null) return;

    // 需求 5.3：本地无结果时自动组织一次答案；`autoAnswer` 开着时每次搜索都自动组织。
    // 没有模型就别触发 —— 那必然是一次失败请求。
    final rt = ref.read(runtimeProvider).value;
    if (!llmConfigured(rt?.llm) || view.advice != null) return;
    if (view.cards.isEmpty || (rt?.search.autoAnswer ?? false)) {
      unawaited(notifier.requestAnswer(q, view.cards));
    }
  }

  void _clearQuery() {
    _controller.clear();
    setState(() {});
    ref.read(memoryStreamProvider.notifier).clearSearch();
    _focus.requestFocus();
  }

  Future<void> _openCard(String id) async {
    final changed = ValueNotifier<bool>(false);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CardDetailScreen(cardId: id, changed: changed),
      ),
    );
    final didChange = changed.value;
    changed.dispose();
    // 改过卡片就重搜一次，否则列表和卡片详情说的不是一回事
    final q = ref.read(memoryStreamProvider).value?.search?.query;
    if (didChange && q != null) await _run(q);
  }

  // ── 语音搜索 ────────────────────────────────────────────────

  void _onHoldStart() {
    if (_recording || _transcribing) return;
    _pressing = true;
    unawaited(_startRecording());
  }

  /// 秒数与 1 分钟自停都靠这个节拍器。只在麦克风真的开了之后才起跑：
  /// 脸一变就等于「已经在录」，用户看到它才开口，前面的开麦空窗就吃不到音。
  void _startTicker() {
    if (_ticker != null) return;
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      if (!_recording) {
        _ticker?.cancel();
        _ticker = null;
        setState(() {});
        return;
      }
      if (shouldAutoStopRecording(_recorder.elapsedMs)) {
        unawaited(_stopRecording());
        return;
      }
      setState(() {});
    });
  }

  void _onHoldEnd() {
    _pressing = false;
    if (_cancelArmed) {
      _cancelArmed = false;
      unawaited(_cancelRecording());
      return;
    }
    // `_recorder.start()` 可能还在等权限：`stop()` 会自己收尾，这里不用管
    if (!_recording && !_recorder.starting) return;
    unawaited(_stopRecording());
  }

  void _onCancelChanged(bool cancel) {
    if (!_recording && !_recorder.starting) return;
    if (_cancelArmed == cancel) return;
    setState(() => _cancelArmed = cancel);
    // 只有「已经进入取消区」才震一下，划回来不再震（同一个手势里不来回报警）
    if (cancel) hapticWarn();
  }

  Future<void> _startRecording() async {
    final rt = ref.read(runtimeProvider).value;
    if (rt?.asr == null) {
      // 没配语音识别：先说清楚，别让用户举着手机对搜索框喊半天
      _pressing = false;
      if (!mounted) return;
      final c = FindrColors.of(context);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: c.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.lg),
          ),
          title: Text(
            '无法语音搜索',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: c.text,
            ),
          ),
          content: Text(
            '尚未配置语音识别。可以先用文字搜；在「设置 → 模型服务」里配一个语音模型即可。',
            style: TextStyle(fontSize: 13, height: 1.5, color: c.textSecondary),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('知道了', style: TextStyle(color: c.record)),
            ),
          ],
        ),
      );
      return;
    }
    try {
      await _recorder.start();
      if (!mounted) return;
      if (!_pressing || !_recorder.recording) {
        await _recorder.cancel();
        return;
      }
      // 麦克风已经在采音了，这一帧才变脸 + 震：脸不撒谎，用户看到它再开口
      setState(() => _recording = true);
      hapticHold();
      _startTicker();
    } on RecorderError catch (e) {
      _pressing = false;
      if (!mounted) return;
      await showRecordAlert(context, e);
    }
  }

  Future<void> _cancelRecording() async {
    _ticker?.cancel();
    _ticker = null;
    await _recorder.cancel();
    if (!mounted) return;
    setState(() => _recording = false);
  }

  Future<void> _stopRecording() async {
    _ticker?.cancel();
    _ticker = null;
    final audio = await _recorder.stop();
    if (!mounted) return;
    setState(() => _recording = false);
    if (audio == null) return; // 太短：当误触丢掉，什么都不发生

    final rt = ref.read(runtimeProvider).value;
    if (rt == null) return;
    setState(() => _transcribing = true);
    String text = '';
    try {
      text = await transcribeOnce(rt, audio.tempPath);
    } catch (e) {
      if (mounted) {
        showFindrToast(context, '语音转文字失败：${plainError(e)}', error: true);
      }
    } finally {
      // 这段录音只为搜索，转完就没有用了
      try {
        final f = File(audio.tempPath);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {
        // 临时目录清不掉不该打扰用户
      }
      if (mounted) setState(() => _transcribing = false);
    }
    if (text.isEmpty) return;
    await _run(text);
  }

  // ── 构建 ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final stream = ref.watch(memoryStreamProvider);
    final s = stream.value;

    return PopScope(
      // 返回键退回记忆流：这页是叠在首页上的，pop 一下就回到了
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) return;
        ref.read(memoryStreamProvider.notifier).clearSearch();
      },
      child: Scaffold(
        backgroundColor: c.background,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: <Widget>[
              _header(c),
              Expanded(child: _body(c, s, stream)),
              _dock(c),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(FindrColors c) {
    return Container(
      color: c.searchSurface,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxContentWidth),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.two,
              Spacing.two,
              Spacing.four,
              Spacing.two,
            ),
            child: Row(
              children: <Widget>[
                Semantics(
                  button: true,
                  label: '返回',
                  child: InkWell(
                    onTap: () => Navigator.of(context).maybePop(),
                    borderRadius: BorderRadius.circular(Radii.pill),
                    child: Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.arrow_back_rounded,
                        size: 20,
                        color: c.textSecondary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.one),
                Text(
                  '搜索',
                  style: TextStyle(fontSize: 14, color: c.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 底部这条坞和首页录入条同一套骨架：左边切输入方式，中间药丸，右边「按下去这件事就结束」。
  /// 搜索也要说话，而手不该伸到屏幕顶上去。
  Widget _dock(FindrColors c) {
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: c.shadow.withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: maxContentWidth),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.three,
                Spacing.two + 2,
                Spacing.three,
                Spacing.two + 2,
              ),
              child: Row(
                children: <Widget>[
                  // 左：切「打字 / 说话」。画的是**下一步**能点成什么，不是当前状态。
                  DockIconButton(
                    icon: _voice
                        ? Icons.keyboard_rounded
                        : Icons.mic_none_rounded,
                    tooltip: _voice ? '切换到文字输入' : '切换到语音输入',
                    onPressed: _recording || _transcribing ? null : _toggleMode,
                  ),
                  const SizedBox(width: Spacing.two),
                  Expanded(child: _voice ? _voicePill(c) : _textPill(c)),
                  const SizedBox(width: Spacing.two),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _controller,
                    builder: (_, value, _) => DockCommitButton(
                      label: '搜',
                      enabled:
                          value.text.trim().isNotEmpty &&
                          !_recording &&
                          !_transcribing,
                      onPressed: () => unawaited(_run(_controller.text)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 切「打字 / 说话」。两种输入不共用一颗药丸，用户不用猜「现在按下去会发生什么」。
  void _toggleMode() {
    if (_voice) {
      // 输入框重新挂上时 `autofocus` 会自己把键盘叫回来 —— 切回打字就是要打字
      setState(() => _voice = false);
      return;
    }
    _focus.unfocus();
    setState(() => _voice = true);
  }

  /// 打字态：一颗真的输入框。药丸和内边距照抄录入条，两页看起来是同一个箱子。
  Widget _textPill(FindrColors c) {
    return Container(
      constraints: const BoxConstraints(minHeight: 38),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      padding: const EdgeInsets.only(
        left: Spacing.three + Spacing.half,
        right: Spacing.two,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              // 进这页那一下已经表达了「要打字」：省掉再点一次输入框
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (v) => unawaited(_run(v)),
              style: TextStyle(fontSize: 14, color: c.text),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                // 提示走 `hint` 而不是 `hintText`：后者跟着 `textAlign` 走，
                // 想要「提示居中、打出来的字靠左」只能自己摆一层。
                hint: Align(
                  alignment: Alignment.center,
                  child: Text(
                    '问一句，比如「护照放哪了」',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: c.textMuted),
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 9.5),
              ),
            ),
          ),
          // 只让这一小块跟随输入变化重建，避免每敲一个字重建整页
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _controller,
            builder: (_, value, _) => value.text.isEmpty
                ? const SizedBox(width: Spacing.two)
                : Semantics(
                    button: true,
                    label: '清除搜索',
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _clearQuery,
                      child: Padding(
                        padding: const EdgeInsets.all(Spacing.two),
                        child: Icon(
                          Icons.close_rounded,
                          size: 18,
                          color: c.textMuted,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// 语音态：这颗药丸就是「按住 说话」本身，不给输入框留位置。
  Widget _voicePill(FindrColors c) => HoldInput(
    enabled: !_transcribing,
    onHoldStart: _onHoldStart,
    onHoldEnd: _onHoldEnd,
    onCancelChanged: _onCancelChanged,
    child: _voiceFace(c),
  );

  /// 语音态的药丸：和录入条那颗「说话」的脸同形 —— 左边一个麦克风，右边一行字。
  /// 说完留着听到的那句：用户要能核对「它到底听成了什么」。
  Widget _voiceFace(FindrColors c) => ValueListenableBuilder<TextEditingValue>(
    valueListenable: _controller,
    builder: (_, value, _) {
      final heard = value.text.trim();
      final String label;
      final Color color;
      final IconData icon;
      if (_transcribing) {
        label = '正在转成文字…';
        color = c.textMuted;
        icon = Icons.mic_none_rounded;
      } else if (_recording) {
        final sec = (_recorder.elapsedMs / 1000).ceil();
        label = _cancelArmed ? '松开取消搜索' : '● 录音中 ${sec}s · 上滑取消';
        // 录着是进行中（主色）；已经划到取消区才是「松手就没了」，这时才配用红
        color = _cancelArmed ? c.danger : c.record;
        icon = Icons.mic_rounded;
      } else if (heard.isEmpty) {
        label = '按住 说话';
        color = c.textMuted;
        icon = Icons.mic_none_rounded;
      } else {
        label = heard;
        color = c.textSecondary;
        icon = Icons.mic_none_rounded;
      }
      return Container(
        constraints: const BoxConstraints(minHeight: 38),
        decoration: BoxDecoration(
          color: _recording
              ? Color.alphaBlend(c.record.withValues(alpha: 0.08), c.surfaceAlt)
              : c.surfaceAlt,
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.three + Spacing.half,
          vertical: 9.5,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              icon,
              size: 15,
              color: _cancelArmed
                  ? c.danger
                  : (_recording ? c.record : c.textMuted),
            ),
            const SizedBox(width: Spacing.one + 2),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: heard.isEmpty || _recording || _transcribing
                      ? 12.5
                      : 14,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
  Widget _body(
    FindrColors c,
    MemoryStreamState? s,
    AsyncValue<MemoryStreamState> stream,
  ) {
    final search = s?.search;
    if (search == null && !(s?.searching ?? false)) {
      return _idle(c);
    }
    final cards = search?.cards ?? const <MemoryCard>[];
    final answer = s?.answer;
    final advice = search?.advice;
    final answering = s?.answering ?? false;
    final byId = <String, Category>{
      for (final cat in s?.categories ?? const <Category>[]) cat.id: cat,
    };
    final showEmpty =
        search != null &&
        !(s?.searching ?? false) &&
        !answering &&
        answer == null &&
        advice == null &&
        cards.isEmpty;

    return ScreenBody(
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.four,
            Spacing.three,
            Spacing.four,
            0,
          ),
          sliver: SliverList.list(
            children: <Widget>[
              if (s?.searching ?? false)
                const Padding(
                  padding: EdgeInsets.only(bottom: Spacing.three),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              if (search != null)
                _ResultsHeader(
                  advice: advice,
                  count: cards.length,
                  canAnswer:
                      cards.isNotEmpty &&
                      answer == null &&
                      advice == null &&
                      !answering,
                  answering: answering,
                  llmReady: llmConfigured(ref.read(runtimeProvider).value?.llm),
                  usage: search.usage,
                  onAnswer: () => unawaited(
                    ref
                        .read(memoryStreamProvider.notifier)
                        .requestAnswer(search.query, cards),
                  ),
                ),
              if (search?.note != null)
                Padding(
                  padding: const EdgeInsets.only(top: Spacing.three),
                  child: Notice(text: search!.note!),
                ),
            ],
          ),
        ),
        // AI 答案/建议置顶：点「AI 总结」后不必滑到列表底部才看到结果
        if (answer != null ||
            advice != null ||
            (answering && answer == null && search != null) ||
            (s?.answerError != null && !answering))
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.four,
              Spacing.three,
              Spacing.four,
              0,
            ),
            sliver: SliverList.list(
              children: <Widget>[
                if (answer != null)
                  _AnswerCard(
                    tag: 'AI 答案',
                    body: answer.answer,
                    extra: answer.suggest.isEmpty ? null : answer.suggest,
                    footer: answer.hitIds.isEmpty
                        ? null
                        : '依据 ${answer.hitIds.length} 张卡片 · 下方已高亮',
                    usage: answer.usage,
                    searchUsage: search?.usage,
                  ),
                if (advice != null)
                  _AnswerCard(
                    tag: 'AI 建议',
                    body: advice.answer,
                    extra: advice.missing.isEmpty
                        ? null
                        : '库里还没有：${advice.missing.join('、')}',
                    extraTone: NoticeTone.warn,
                    footer:
                        '必需 ${advice.picks.length} 项'
                        '${advice.maybe.isEmpty ? '' : ' · 看情况 ${advice.maybe.length} 项'}',
                    usage: advice.usage ?? search?.usage,
                  ),
                // 渐进式的唯一指示器：放在答案即将出现的位置
                if (answering && answer == null && search != null)
                  const Notice(text: '正在组织答案…'),
                if (s?.answerError != null && !answering)
                  Notice(
                    title: '无法生成答案',
                    text: s!.answerError!,
                    tone: NoticeTone.warn,
                    action: Text(
                      cards.isNotEmpty
                          ? '卡片列表不受影响，点「AI 总结」可重试。'
                          : '可以换个说法再搜一次。',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: FindrColors.of(context).textMuted,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            Spacing.four,
            answer == null && advice == null && s?.answerError == null
                ? Spacing.three
                : Spacing.two,
            Spacing.four,
            Spacing.six,
          ),
          sliver: SliverList.list(
            children: <Widget>[
              if (showEmpty)
                EmptyState(
                  icon: Icons.search_off_rounded,
                  title: '没找到相关记忆',
                  hint: llmConfigured(ref.read(runtimeProvider).value?.llm)
                      ? '换个说法试试'
                      : '尚未配置模型，仅做字面匹配。试试更具体的词，'
                            '或用空格分开，比如「护照 柜子」。',
                ),
              for (final card in cards)
                Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.three),
                  child: CardRow(
                    card: card,
                    ctx: _badgeCtx(),
                    categoryName: card.categoryId == null
                        ? null
                        : byId[card.categoryId]?.name,
                    categoryEmoji: card.categoryId == null
                        ? null
                        : byId[card.categoryId]?.emoji,
                    highlight: answer?.hitIds.contains(card.id) ?? false,
                    note: adviceNoteOf(advice, card.id),
                    onTap: () => unawaited(_openCard(card.id)),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 空搜索时的样子：最近搜索 + 一句「没有做什么」的空态。
  Widget _idle(FindrColors c) {
    if (_recent.isEmpty) {
      return const ScreenBody(
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: EmptyState(
              icon: Icons.search_rounded,
              title: '搜索记忆',
              hint: '地名、物品或一句话，例如「护照 柜子」',
            ),
          ),
        ],
      );
    }
    return ScreenBody.column(
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              '最近搜索',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: c.textSecondary,
              ),
            ),
            const Spacer(),
            GestureDetector(
              onTap: () {
                final rt = ref.read(runtimeProvider).value;
                if (rt != null) deleteSetting(rt.driver, kRecentSearchesKey);
                setState(() => _recent = const <String>[]);
              },
              child: Text(
                '清空',
                style: TextStyle(fontSize: 12.5, color: c.textMuted),
              ),
            ),
          ],
        ),
        Wrap(
          spacing: Spacing.two,
          runSpacing: Spacing.two,
          children: <Widget>[
            for (final item in _recent)
              FindrChip(
                label: item,
                dense: true,
                canvas: true,
                onPressed: () => unawaited(_run(item)),
              ),
          ],
        ),
      ],
    );
  }

  BadgeContext _badgeCtx() {
    final rt = ref.read(runtimeProvider).value;
    return BadgeContext(
      visionSupported: visionSupported(rt?.llm),
      asrConfigured: asrReady(rt?.asr),
      modelConfigured: llmConfigured(rt?.llm),
    );
  }
}

/// 结果区标题行。
class _ResultsHeader extends StatelessWidget {
  const _ResultsHeader({
    required this.advice,
    required this.count,
    required this.canAnswer,
    required this.answering,
    required this.llmReady,
    required this.onAnswer,
    this.usage,
  });

  final AdviceResult? advice;
  final int count;
  final bool canAnswer;

  /// 答案正在生成：按钮留在原位显示 loading，不要整颗消失。
  final bool answering;

  final bool llmReady;
  final VoidCallback onAnswer;
  final ChatUsage? usage;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final countText = advice != null ? '挑出 $count 条' : '检索结果 $count 条';
    return Row(
      children: <Widget>[
        Expanded(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                countText,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: c.textSecondary,
                ),
              ),
              if (advice == null && usage != null && usage!.total > 0) ...[
                const SizedBox(width: Spacing.two),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1.5,
                  ),
                  decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(Radii.xs),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.bolt_rounded, size: 11, color: c.textMuted),
                      const SizedBox(width: 2),
                      Text(
                        '${usage!.total} tokens',
                        style: TextStyle(fontSize: 10.5, color: c.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        // 没有模型时不给「AI 总结」入口 —— 点了必然失败。
        // 建议型结果也不给：那一屏的答案就是裁决本身，再总结一次是重复劳动。
        // 正在生成时按钮留在原位显示 loading —— 让它消失会看起来像「点了没反应」。
        if ((canAnswer || answering) && llmReady)
          FindrButton(
            title: 'AI 总结',
            variant: FindrButtonVariant.ghost,
            compact: true,
            expand: false,
            loading: answering,
            onPressed: onAnswer,
          ),
      ],
    );
  }
}

/// 结果头下方的答案 / 建议卡。两者版式相同、内容不同，所以共用一个组件。
class _AnswerCard extends StatelessWidget {
  const _AnswerCard({
    required this.tag,
    required this.body,
    this.extra,
    this.extraTone = NoticeTone.info,
    this.footer,
    this.usage,
    this.searchUsage,
  });

  final String tag;
  final String body;
  final String? extra;
  final NoticeTone extraTone;
  final String? footer;
  final ChatUsage? usage;
  final ChatUsage? searchUsage;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final extraColor = extraTone == NoticeTone.warn
        ? c.badgeConfirm
        : c.textSecondary;

    final sTokens = searchUsage?.total ?? 0;
    final aTokens = usage?.total ?? 0;
    String? usageText;
    if (sTokens > 0 && aTokens > 0) {
      usageText = '${sTokens + aTokens} tokens（搜索 $sTokens · 总结 $aTokens）';
    } else if (aTokens > 0) {
      usageText = '用量：$aTokens tokens';
    } else if (sTokens > 0) {
      usageText = '用量：$sTokens tokens';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: Spacing.three),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(Radii.lg),
        boxShadow: [
          BoxShadow(
            color: c.record.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
          BoxShadow(color: c.shadow, blurRadius: 6, offset: const Offset(0, 1)),
        ],
      ),
      padding: const EdgeInsets.all(Spacing.four),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.two,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              color: c.record.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(Radii.xs),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.auto_awesome_rounded, size: 12, color: c.record),
                const SizedBox(width: 4),
                Text(
                  tag,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: c.record,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Spacing.two),
          Text(
            body,
            style: TextStyle(fontSize: 15, height: 1.55, color: c.text),
          ),
          if (extra != null) ...<Widget>[
            const SizedBox(height: Spacing.two),
            Text(
              extra!,
              style: TextStyle(fontSize: 12.5, height: 1.45, color: extraColor),
            ),
          ],
          if (footer != null) ...<Widget>[
            const SizedBox(height: Spacing.two),
            Text(footer!, style: TextStyle(fontSize: 11, color: c.textMuted)),
          ],
          if (usageText != null) ...<Widget>[
            const SizedBox(height: Spacing.two),
            Row(
              children: [
                Icon(Icons.bolt_rounded, size: 13, color: c.record),
                const SizedBox(width: 3),
                Text(
                  usageText,
                  style: TextStyle(
                    fontSize: 11,
                    color: c.record,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
