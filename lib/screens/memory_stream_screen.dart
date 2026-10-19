/// 首页：记忆流。
///
/// **四条口径一个字都不能变**：
///
/// 1. **上「查」下「记」两条链路强区分**：上面是中性冷灰的检索区，下面是品牌蓝的录入坞。
///    需求六明确说合并会丢数据，所以别为了「好看」把它们统一成一种材质。
/// 2. **记忆流必须是滚动容器**。列表容器若不具备滚动能力，
///    卡片一多就只是「被下边缘挡住」而划不动（真机反馈：首页列表划不动）。
///    这里用 `CustomScrollView`，且内外边距全在 sliver 的 padding 上 ——
///    写在容器 `style` 上会把内容区压掉一圈，滚动时首尾卡片贴边。
/// 3. **AI 答案追加在列表下方，不置顶**。答案晚一两秒才回来，置顶会把正在读的列表整块推下去。
/// 4. **「走的是哪条检索路」必须说清**（没配模型 / 模型不可达 / 放宽了条件 / 没听懂），
///    否则用户会把「字面没搜到」读成「卡片丢了」。
library;

import 'dart:async';

import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../capture/composer.dart';
import '../capture/submit.dart';
import '../platform/network.dart';
import '../platform/runtime.dart';
import '../state/memory_stream.dart';
import '../theme/tokens.dart';
import '../ui/card_row.dart';
import '../ui/kit.dart';
import 'card_detail_screen.dart';
import 'settings/categories_screen.dart';
import 'settings/provider_settings_screen.dart';
import 'settings/settings_screen.dart';

class MemoryStreamScreen extends ConsumerStatefulWidget {
  const MemoryStreamScreen({super.key});

  @override
  ConsumerState<MemoryStreamScreen> createState() => _MemoryStreamScreenState();
}

class _MemoryStreamScreenState extends ConsumerState<MemoryStreamScreen>
    with WidgetsBindingObserver {
  final _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _query.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // App 回前台补跑队列（补齐在后台/无网时没跑完的解析）
    if (state == AppLifecycleState.resumed) {
      unawaited(_drainQueue());
    }
  }

  Future<void> _drainQueue() async {
    try {
      await ref.read(memoryStreamProvider.notifier).drainQueue();
    } catch (_) {
      // 补跑失败不改库里的素材；卡片自己会带「重试中」角标
    }
  }

  Future<void> _doSearch() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    final notifier = ref.read(memoryStreamProvider.notifier);
    await notifier.search(q);
    // 需求 5.3：本地无结果时自动组织一次答案；`autoAnswer` 开着时「每次搜索都自动组织」也走这里。
    // 没有模型就别触发 —— 那必然是一次失败请求。
    final s = ref.read(memoryStreamProvider).value;
    if (s == null) return;
    final rt = ref.read(runtimeProvider).value;
    final llmReady = llmConfigured(rt?.llm);
    final autoAnswer = rt?.search.autoAnswer ?? false;
    final res = s.search;
    if (llmReady && res != null && res.advice == null && (res.cards.isEmpty || autoAnswer)) {
      // **刻意不 await**：列表已经渲染出来了，答案回来再追加到下方（渐进式）
      unawaited(notifier.requestAnswer(q, res.cards));
    }
  }

  void _clearSearch() {
    _query.clear();
    ref.read(memoryStreamProvider.notifier).clearSearch();
  }

  /// 录完一条：**先落盘**（草稿立即可见），再在后台推进解析队列。
  ///
  /// 「先落盘」是硬顺序：图片/录音在这里才进媒体目录，卡片行随后插入。
  /// 中间任何一步失败都只会让这次录入白费，**不会**留下一条有记录没素材的卡片
  /// （见 `capture/submit.dart` 的文件头）。
  Future<void> _submit(ComposerPayload payload) async {
    final rt = ref.read(runtimeProvider).value;
    if (rt == null) {
      _toast('还没准备好，稍等一下');
      return;
    }
    // 记住这次的图片分析选择，下次默认沿用（需求 5.1）。只有**手动切过**才写。
    final override = payload.visionOverride;
    if (override != null && override != rt.capture.visionLast) {
      writeCaptureSettings(
        rt.driver,
        CaptureSettings(
          visionDefault: rt.capture.visionDefault,
          visionLast: override,
          maxAnalyzeImages: rt.capture.maxAnalyzeImages,
        ),
      );
    }
    try {
      await persistCapture(
        rt.driver,
        CaptureSubmission(
          text: payload.text,
          photos: payload.photos,
          audio: payload.audio,
          attachments: payload.attachments,
        ),
      );
    } catch (e) {
      _toast('没能存下：$e');
      return;
    }
    // 草稿立刻出现在流里 —— 这是「先落盘、素材永不丢失」给用户看的证据
    await ref.read(memoryStreamProvider.notifier).reload();
    // 队列要跑模型调用，几秒到几十秒；**不能让录入条一直转**，所以放后台
    unawaited(_advanceAfterSubmit());
  }

  Future<void> _advanceAfterSubmit() async {
    try {
      // 重读运行时：录入条上的开关（如图片分析）刚变过，`rt.capture` 还是旧快照
      await ref.read(runtimeProvider.notifier).refresh();
      await ref.read(memoryStreamProvider.notifier).drainQueue();
    } catch (_) {
      // 同上：失败只是留在「待解析」，素材没丢
    }
  }

  void _toast(String message) {
    final c = FindrColors.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, style: TextStyle(fontSize: 13, color: c.text)),
          backgroundColor: c.surface,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _openCard(String id) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => CardDetailScreen(cardId: id)),
    );
    await ref.read(memoryStreamProvider.notifier).reload();
  }

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final stream = ref.watch(memoryStreamProvider);
    final rtAsync = ref.watch(runtimeProvider);

    final rt = rtAsync.value;
    final llmReady = llmConfigured(rt?.llm);
    final state = stream.value;

    return Scaffold(
      backgroundColor: c.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            _SearchBar(
              controller: _query,
              onSubmit: () => unawaited(_doSearch()),
              onClear: _clearSearch,
              onSettings: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
              ),
              categories: state?.categories ?? const <Category>[],
              categoryFilter: state?.categoryFilter,
              onCategory: (id) => ref.read(memoryStreamProvider.notifier).setCategory(id),
              onNewCategory: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const CategoriesScreen()),
              ),
              llmReady: llmReady,
            ),
            Expanded(child: _buildFlow(context, stream, rtAsync)),
            Composer(
              busy: false,
              // 「记」这一侧只报**非模型类**的降级原因。没配模型已在顶部提示条里说过，
              // 这里再说一遍只会让同一屏出现两段几乎一样的话。
              notice: _composerNotice(rt),
              // 图片分析开关：模型能力 + 设置里的默认值（`effectiveVision` 已把两个因素合起来）
              visionCapable: visionSupported(rt?.llm),
              visionDefault: rt == null ? true : currentVision(rt),
              onSubmit: _submit,
            ),
          ],
        ),
      ),
    );
  }

  /// 录入坞上方的提示条。
  ///
  /// ⚠️ **这里容易写错一条**：别把提示条件写成「`autoAnswer` 开着就不提示没配 ASR」——
  /// `autoAnswer` 是**检索**侧的开关，跟 ASR 毫无关系，那样写的结果是
  /// 「打开了自动总结答案的用户，永远看不到自己其实没配 ASR」。
  /// 正确的条件只有 `offline || noAsr`，没有 `autoAnswer` 这一项。
  ///
  /// 离线排在前：它决定的是**当下能不能用**，比「缺个 ASR」更急。
  Widget? _composerNotice(RuntimeState? rt) {
    final online = ref.watch(onlineProvider).value ?? true;
    if (!online) {
      return const Notice(
        text: '当前无网络：先拍照或打字，稍后联网会自动补上解析。',
        tone: NoticeTone.warn,
      );
    }
    return null;
  }

  Widget _buildFlow(
    BuildContext context,
    AsyncValue<MemoryStreamState> stream,
    AsyncValue<RuntimeState> rtAsync,
  ) {
    final s = stream.value;

    if (rtAsync.isLoading && s == null) {
      return const Center(child: CircularProgressIndicator());
    }
    // 数据库都没打开的话其余界面全是空转；必须让用户看得见原因
    final fatal = rtAsync.error != null ? '$rtAsync.error' : s?.loadError;
    if (fatal != null && s == null) {
      return ScreenBody.column(
        children: <Widget>[
          Notice(title: '数据库没能打开', text: fatal, tone: NoticeTone.danger),
        ],
      );
    }

    final search = s?.search;
    final cards = search?.cards ?? s?.cards ?? const <MemoryCard>[];
    final answer = s?.answer;
    final advice = search?.advice;
    final answering = s?.answering ?? false;
    final searching = s?.searching ?? false;
    final showEmpty = !searching && answer == null && advice == null && !answering && cards.isEmpty;

    final byId = <String, Category>{
      for (final cat in s?.categories ?? const <Category>[]) cat.id: cat,
    };

    final slivers = <Widget>[
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(Spacing.four, Spacing.three, Spacing.four, 0),
        sliver: SliverList.list(
          children: <Widget>[
            if (s?.loadError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.three),
                child: Notice(title: '读取卡片失败', text: s!.loadError!, tone: NoticeTone.danger),
              ),
            if (searching)
              const Padding(
                padding: EdgeInsets.only(bottom: Spacing.three),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (search != null) ...<Widget>[
              _ResultsHeader(
                advice: advice,
                count: cards.length,
                canAnswer: cards.isNotEmpty && answer == null && advice == null && !answering,
                llmReady: llmConfigured(ref.read(runtimeProvider).value?.llm),
                usage: search.usage,
                onAnswer: () => unawaited(
                  ref.read(memoryStreamProvider.notifier).requestAnswer(search.query, cards),
                ),
                onBack: _clearSearch,
              ),
              const SizedBox(height: Spacing.three),
            ],
            if (search?.note != null)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.three),
                child: Notice(text: search!.note!),
              ),
          ],
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(Spacing.four, 0, Spacing.four, Spacing.three),
        sliver: SliverList.separated(
          itemCount: cards.length,
          separatorBuilder: (_, _) => const SizedBox(height: Spacing.three),
          itemBuilder: (_, i) {
            final card = cards[i];
            final cat = card.categoryId == null ? null : byId[card.categoryId];
            return CardRow(
              card: card,
              ctx: _badgeCtx(),
              categoryName: cat?.name,
              categoryEmoji: cat?.emoji,
              highlight: answer?.hitIds.contains(card.id) ?? false,
              note: _adviceNote(advice, card.id),
              onTap: () => unawaited(_openCard(card.id)),
            );
          },
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(Spacing.four, 0, Spacing.four, Spacing.five),
        sliver: SliverList.list(
          children: <Widget>[
            // AI 答案：**追加在列表下方**，不置顶（需求六已据此改）
            if (answer != null)
              _AnswerCard(
                tag: 'AI 答案',
                body: answer.answer,
                extra: answer.suggest.isEmpty ? null : answer.suggest,
                footer: answer.hitIds.isEmpty
                    ? null
                    : '依据 ${answer.hitIds.length} 张卡片，已在上方高亮',
                usage: answer.usage,
                searchUsage: search?.usage,
              ),
            if (advice != null)
              _AnswerCard(
                tag: 'AI 建议',
                body: advice.answer,
                extra: advice.missing.isEmpty ? null : '库里还没有：${advice.missing.join('、')}',
                extraTone: NoticeTone.warn,
                footer: '必需 ${advice.picks.length} 项'
                    '${advice.maybe.isEmpty ? '' : ' · 看情况 ${advice.maybe.length} 项'}',
                usage: advice.usage ?? search?.usage,
              ),
            // 渐进式的唯一指示器：列表已经能用，答案还在路上。刻意放在答案即将出现的位置
            if (answering && answer == null && search != null)
              const Notice(text: '正在组织答案…'),
            // 答案没生成出来：**不占「AI 答案」的位置**，也不盖掉空态 ——
            // 列表本身是好的，这只是一次附加调用没跑成
            if (s?.answerError != null && !answering)
              Notice(
                title: '没能组织答案',
                text: s!.answerError!,
                tone: NoticeTone.warn,
                action: Text(
                  cards.isNotEmpty ? '卡片列表不受影响，可以点「AI 总结」重试。' : '可以换个说法再搜一次。',
                  style: TextStyle(fontSize: 11.5, color: FindrColors.of(context).textMuted),
                ),
              ),
            // 空态。正在组织答案时先不喊「没找到」，否则会先闪一句空话再被答案推翻。
            // 建议型结果也一样：卡片可能一条都没挑出来，但那一屏有价值的是「你还缺什么」。
            if (showEmpty)
              EmptyState(
                icon: search != null ? Icons.search_off_rounded : Icons.inbox_outlined,
                title: search != null ? '没找到相关记忆' : '还没有记忆',
                hint: search != null
                    ? (llmConfigured(ref.read(runtimeProvider).value?.llm)
                          ? '换个说法试试，或者先看看底部怎么记一笔'
                          : '当前没有可用模型，只做了关键词字面匹配。试试更具体的词，'
                                '或把几个关键词用空格分开，比如「护照 柜子」。')
                    : '用底部的输入框记下第一笔',
              ),
          ],
        ),
      ),
    ];

    return ScreenBody(slivers: slivers);
  }

  BadgeContext _badgeCtx() {
    final rt = ref.read(runtimeProvider).value;
    return BadgeContext(
      visionSupported: visionSupported(rt?.llm),
      asrConfigured: rt?.asr != null,
    );
  }
}

/// 建议型结果里每张卡的入选理由（advise 专有）。
///
/// **必须给理由**：这类结果不是字面命中，是模型挑出来的 —— 不给理由用户无从判断该不该信。
/// 「看情况」那一档尤其要带前缀，否则它和「必需」在列表里长得一模一样。
String? _adviceNote(AdviceResult? a, String cardId) {
  if (a == null) return null;
  for (final p in a.picks) {
    if (p.id == cardId) return p.why.isEmpty ? null : p.why;
  }
  for (final m in a.maybe) {
    if (m.id == cardId) {
      return '看情况：${m.why.isEmpty ? '取决于你的具体情况' : m.why}';
    }
  }
  return null;
}

/// 顶部「查」区：搜索框 + 设置入口 + 分类 Chip 栏。
class _SearchBar extends StatefulWidget {
  const _SearchBar({
    required this.controller,
    required this.onSubmit,
    required this.onClear,
    required this.onSettings,
    required this.categories,
    required this.categoryFilter,
    required this.onCategory,
    required this.onNewCategory,
    required this.llmReady,
  });

  final TextEditingController controller;
  final VoidCallback onSubmit;
  final VoidCallback onClear;
  final VoidCallback onSettings;
  final List<Category> categories;
  final String? categoryFilter;
  final ValueChanged<String?> onCategory;
  final VoidCallback onNewCategory;
  final bool llmReady;

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    return Container(
      color: c.searchSurface,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxContentWidth),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.four,
              Spacing.three,
              Spacing.four,
              Spacing.three,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: c.surfaceSunken,
                          borderRadius: BorderRadius.circular(Radii.pill),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: Spacing.four),
                        child: Row(
                          children: <Widget>[
                            Icon(Icons.search_rounded, size: 18, color: c.search),
                            const SizedBox(width: Spacing.two),
                            Expanded(
                              child: TextField(
                                controller: widget.controller,
                                textInputAction: TextInputAction.search,
                                onSubmitted: (_) => widget.onSubmit(),
                                style: TextStyle(fontSize: 14.5, color: c.text),
                                decoration: InputDecoration(
                                  isDense: true,
                                  border: InputBorder.none,
                                  hintText: '问一句，比如「护照放哪了」',
                                  hintStyle: TextStyle(fontSize: 14, color: c.textMuted),
                                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                                ),
                              ),
                            ),
                            if (widget.controller.text.isNotEmpty)
                              GestureDetector(
                                onTap: widget.onClear,
                                child: Icon(Icons.close_rounded, size: 18, color: c.textMuted),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: Spacing.two),
                    Container(
                      decoration: BoxDecoration(
                        color: c.surfaceSunken,
                        borderRadius: BorderRadius.circular(Radii.pill),
                      ),
                      child: IconButton(
                        onPressed: widget.onSettings,
                        icon: const Icon(Icons.settings_outlined, size: 20),
                        color: c.textSecondary,
                        tooltip: '设置',
                        padding: const EdgeInsets.all(Spacing.two),
                        constraints: const BoxConstraints(minWidth: 42, minHeight: 42),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.two),
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOutCubic,
                  alignment: Alignment.topCenter,
                  child: !_expanded
                      ? Row(
                          children: <Widget>[
                            Expanded(
                              child: SizedBox(
                                height: 32,
                                child: ShaderMask(
                                  shaderCallback: (Rect bounds) {
                                    return const LinearGradient(
                                      begin: Alignment.centerLeft,
                                      end: Alignment.centerRight,
                                      colors: <Color>[
                                        Colors.white,
                                        Colors.white,
                                        Colors.transparent,
                                      ],
                                      stops: <double>[0.0, 0.88, 1.0],
                                    ).createShader(bounds);
                                  },
                                  blendMode: BlendMode.dstIn,
                                  child: ListView.separated(
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.only(right: Spacing.two),
                                    itemCount: widget.categories.length + 2,
                                    separatorBuilder: (_, _) => const SizedBox(width: Spacing.two),
                                    itemBuilder: (_, i) {
                                      if (i == 0) {
                                        return FindrChip(
                                          label: '全部',
                                          dense: true,
                                          canvas: true,
                                          active: widget.categoryFilter == null,
                                          onPressed: () => widget.onCategory(null),
                                        );
                                      }
                                      if (i == widget.categories.length + 1) {
                                        return FindrChip(
                                          label: '＋ 新建分类',
                                          dense: true,
                                          canvas: true,
                                          onPressed: widget.onNewCategory,
                                        );
                                      }
                                      final cat = widget.categories[i - 1];
                                      return FindrChip(
                                        label: cat.name,
                                        dense: true,
                                        canvas: true,
                                        active: widget.categoryFilter == cat.id,
                                        onPressed: () => widget.onCategory(widget.categoryFilter == cat.id ? null : cat.id),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                            if (widget.categories.isNotEmpty) ...<Widget>[
                              const SizedBox(width: Spacing.two),
                              Material(
                                color: c.surfaceSunken,
                                borderRadius: BorderRadius.circular(Radii.pill),
                                child: InkWell(
                                  onTap: () => setState(() => _expanded = true),
                                  borderRadius: BorderRadius.circular(Radii.pill),
                                  child: Container(
                                    width: 32,
                                    height: 32,
                                    alignment: Alignment.center,
                                    child: Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: c.textSecondary),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        )
                      : Container(
                          decoration: BoxDecoration(
                            color: c.surface,
                            borderRadius: BorderRadius.circular(Radii.md),
                          ),
                          padding: const EdgeInsets.all(Spacing.three),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: <Widget>[
                                  Text(
                                    '全部分类（${widget.categories.length}）',
                                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.textSecondary),
                                  ),
                                  GestureDetector(
                                    onTap: () => setState(() => _expanded = false),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: <Widget>[
                                        Text('收起', style: TextStyle(fontSize: 12, color: c.textMuted)),
                                        const SizedBox(width: 2),
                                        Icon(Icons.keyboard_arrow_up_rounded, size: 18, color: c.textMuted),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: Spacing.two),
                              Wrap(
                                spacing: Spacing.two,
                                runSpacing: Spacing.two,
                                children: <Widget>[
                                  FindrChip(
                                    label: '全部',
                                    dense: true,
                                    canvas: true,
                                    active: widget.categoryFilter == null,
                                    onPressed: () => widget.onCategory(null),
                                  ),
                                  for (final cat in widget.categories)
                                    FindrChip(
                                      label: cat.name,
                                      dense: true,
                                      canvas: true,
                                      active: widget.categoryFilter == cat.id,
                                      onPressed: () => widget.onCategory(widget.categoryFilter == cat.id ? null : cat.id),
                                    ),
                                  FindrChip(
                                    label: '＋ 新建分类',
                                    dense: true,
                                    canvas: true,
                                    onPressed: widget.onNewCategory,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                ),
                // 未配模型的提示条。
                // ⚠️ **必须在正常文档流里**：做成绝对定位（`position:'absolute', top:8`）会
                // 正好盖住搜索框；而多数用户一开始都没配模型 ⇒ 搜索框被永久遮住，
                // 表现为「找不到搜索入口」（真机反馈）。别再改回浮层。
                if (!widget.llmReady) ...<Widget>[
                  const SizedBox(height: Spacing.two),
                  GestureDetector(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => const ProviderSettingsScreen()),
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: Spacing.three, vertical: 7),
                      decoration: BoxDecoration(
                        color: c.surfaceAlt.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(Radii.pill),
                      ),
                      child: Row(
                        children: <Widget>[
                          Icon(Icons.info_outline_rounded, size: 14, color: c.textMuted),
                          const SizedBox(width: Spacing.two),
                          Expanded(
                            child: Text(
                              '还没配置模型：内容都留在本地，随时能翻找和编辑。点这里填写 →',
                              style: TextStyle(fontSize: 11.5, color: c.textSecondary),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 结果区标题行。
class _ResultsHeader extends StatelessWidget {
  const _ResultsHeader({
    required this.advice,
    required this.count,
    required this.canAnswer,
    required this.llmReady,
    required this.onAnswer,
    required this.onBack,
    this.usage,
  });

  final AdviceResult? advice;
  final int count;
  final bool canAnswer;
  final bool llmReady;
  final VoidCallback onAnswer;
  final VoidCallback onBack;
  final ChatUsage? usage;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final countText = advice != null ? '为你挑出 $count 条' : '检索结果 $count 条';
    return Row(
      children: <Widget>[
        Expanded(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                countText,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textSecondary),
              ),
              if (advice == null && usage != null && usage!.total > 0) ...[
                const SizedBox(width: Spacing.two),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
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
        if (canAnswer && llmReady)
          FindrButton(
            title: 'AI 总结',
            variant: FindrButtonVariant.ghost,
            compact: true,
            expand: false,
            onPressed: onAnswer,
          ),
        FindrButton(
          title: '回到记忆流',
          variant: FindrButtonVariant.ghost,
          compact: true,
          expand: false,
          onPressed: onBack,
        ),
      ],
    );
  }
}

/// 列表下方的答案 / 建议卡。两者版式相同、内容不同，所以共用一个组件。
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
    final extraColor = extraTone == NoticeTone.warn ? c.badgeConfirm : c.textSecondary;

    final sTokens = searchUsage?.total ?? 0;
    final aTokens = usage?.total ?? 0;
    String? usageText;
    if (sTokens > 0 && aTokens > 0) {
      usageText = '总用量：${sTokens + aTokens} tokens（搜索 $sTokens + 总结 $aTokens）';
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
          BoxShadow(
            color: c.shadow,
            blurRadius: 6,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      padding: const EdgeInsets.all(Spacing.four),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.two, vertical: 2),
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
          Text(body, style: TextStyle(fontSize: 15, height: 1.55, color: c.text)),
          if (extra != null) ...<Widget>[
            const SizedBox(height: Spacing.two),
            Text(extra!, style: TextStyle(fontSize: 12.5, height: 1.45, color: extraColor)),
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
