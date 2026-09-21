/// 卡片详情 —— 对应 RN 的 `app/card/[id].tsx`。
///
/// **首屏 = 用户自己录进来的原始素材：原文 → 录音 → 照片。**
/// RN 那边这段曾经是错的：照片压根没渲染、原文藏在第四个输入框里、音频播放器排第三个面板，
/// 用户点进来第一眼看不到「我记了什么」，只看到一堆分类/状态选择器（真机反馈）。
/// 所以这一版的顺序是硬约束：**先素材，后编辑，最后才是归档/删除**。
///
/// ⚠️ **录音播放还没接**（要引音频播放依赖，与媒体录入同一块）。现在只显示「有录音」与路径，
/// **不画一个点了没反应的按钮** —— 那比没有更糟。
library;

import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/runtime.dart';
import '../theme/tokens.dart';
import '../ui/card_row.dart';
import '../ui/kit.dart';
import '../ui/media_view.dart';

class CardDetailScreen extends ConsumerStatefulWidget {
  const CardDetailScreen({super.key, required this.cardId});

  final String cardId;

  @override
  ConsumerState<CardDetailScreen> createState() => _CardDetailScreenState();
}

class _CardDetailScreenState extends ConsumerState<CardDetailScreen> {
  /// 写库之后 `++` 一下强制重读。
  int _tick = 0;

  /// 「步骤」按内容出现：有步骤时自动展开，没有则收起 —— 多数记忆本来就没有步骤。
  bool _stepsOpen = false;

  bool _busy = false;
  bool _editorsReady = false;

  final _transcript = TextEditingController();
  final _desc = TextEditingController();
  final _entity = TextEditingController();
  final _tags = TextEditingController();

  @override
  void dispose() {
    _transcript.dispose();
    _desc.dispose();
    _entity.dispose();
    _tags.dispose();
    super.dispose();
  }

  /// 把库里当前的值填进输入框。**只在第一次填** ——
  /// 若每次 build 都覆写，用户打字打到一半会被库里那份盖回去（看起来像「我打的字被吃了」）。
  void _fillEditors(MemoryCard card) {
    if (_editorsReady) return;
    _editorsReady = true;
    _transcript.text = card.transcript ?? '';
    _desc.text = card.desc ?? '';
    _entity.text = card.entity ?? '';
    _tags.text = (card.tags ?? const <String>[]).join('、');
  }

  void _patch(CardPatch patch) {
    final rt = ref.read(runtimeProvider).value;
    if (rt == null) return;
    updateCardFields(rt.driver, widget.cardId, patch, DateTime.now());
    setState(() => _tick++);
  }

  void _reload() => setState(() => _tick++);

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

  Future<void> _run(Future<Object?> Function(AdvanceDeps deps) body, String label) async {
    setState(() => _busy = true);
    try {
      final rt = ref.read(runtimeProvider).value;
      if (rt == null) return;
      final res = await body(requireDeps(rt));
      _reload();
      final outcome = res is AdvanceResult ? res.outcome : null;
      if (outcome == AdvanceOutcome.retry) {
        _toast('$label 失败，稍后可以再试一次。');
      } else {
        _toast('$label 完成');
      }
    } catch (e) {
      _toast('$label 失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final c = FindrColors.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: Text('删除这张卡片？', style: TextStyle(fontSize: 16, color: c.text)),
        content: Text(
          '卡片和它的图片、录音都会一起删掉，不可恢复。',
          style: TextStyle(fontSize: 13, height: 1.5, color: c.textSecondary),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: c.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('删除', style: TextStyle(color: c.danger)),
          ),
        ],
      ),
    );
    if (yes != true) return;
    final rt = ref.read(runtimeProvider).value;
    if (rt == null) return;
    deleteCard(rt.driver, widget.cardId);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _pickLocation(List<LocationNode> all) async {
    final c = FindrColors.of(context);
    final byId = <String, LocationNode>{for (final l in all) l.id: l};
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: c.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl)),
      ),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.all(Spacing.four),
                child: Text(
                  '选一个位置',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.text),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: <Widget>[
                    for (final node in _flatten(all))
                      ListRow(
                        title: node.name,
                        subtitle: _chainOf(byId, node).names.join(' / '),
                        onTap: () => Navigator.of(ctx).pop(node.id),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(Spacing.three),
                child: Text(
                  '要新建位置？去「设置 → 位置树」。位置也会在解析时自动长出来。',
                  style: TextStyle(fontSize: 11.5, color: c.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (chosen == null) return;
    final chain = _chainOf(byId, byId[chosen]!);
    _patch(
      CardPatch(pathIds: chain.ids, pathNames: chain.names.join('/'), pathSuggestion: null),
    );
  }

  /// 深度优先展开成「父在前、子在后」的一维表（详情页不需要真的画树）。
  List<LocationNode> _flatten(List<LocationNode> all) {
    final out = <LocationNode>[];
    void walk(String? pid) {
      final kids = all.where((l) => l.parentId == pid).toList()
        ..sort((a, b) => a.sort.compareTo(b.sort));
      for (final k in kids) {
        out.add(k);
        walk(k.id);
      }
    }

    walk(null);
    return out;
  }

  /// 从根到该节点的 id 链与名字链。
  ({List<String> ids, List<String> names}) _chainOf(
    Map<String, LocationNode> byId,
    LocationNode node,
  ) {
    final ids = <String>[];
    final names = <String>[];
    LocationNode? cursor = node;
    while (cursor != null) {
      ids.insert(0, cursor.id);
      names.insert(0, cursor.name);
      final pid = cursor.parentId;
      cursor = pid == null ? null : byId[pid];
    }
    return (ids: ids, names: names);
  }

  @override
  Widget build(BuildContext context) {
    // 读一次 _tick 让它参与重建
    final _ = _tick;
    final c = FindrColors.of(context);
    final rt = ref.watch(runtimeProvider).value;
    if (rt == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final card = getCard(rt.driver, widget.cardId);
    if (card == null) {
      return Scaffold(
        appBar: FindrTopBar(title: '卡片'),
        body: const Center(child: Text('卡片不存在，可能已被删除。')),
      );
    }
    _fillEditors(card);

    final categories = listCategories(rt.driver);
    final locations = listLocations(rt.driver);
    final ctx = BadgeContext(
      visionSupported: visionSupported(rt.llm),
      asrConfigured: rt.asr != null,
    );
    final badges = cardBadges(card);
    final images = card.images ?? const <String>[];
    final steps = card.steps ?? const <StepItem>[];
    final showSteps = _stepsOpen || steps.isNotEmpty;

    return Scaffold(
      appBar: FindrTopBar(
        title: '卡片',
        actions: <Widget>[
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.check_rounded, size: 22),
            color: c.record,
            tooltip: '完成',
          ),
        ],
      ),
      body: ScreenBody.column(
        padding: const EdgeInsets.fromLTRB(
          Spacing.four,
          Spacing.four,
          Spacing.four,
          Spacing.six,
        ),
        children: <Widget>[
          // ── 首屏：原始素材 ───────────────────────────────
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  cardTitleOf(card),
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c.text),
                ),
                if (badges.isNotEmpty || card.status == CardStatus.archived) ...<Widget>[
                  const SizedBox(height: Spacing.three),
                  Wrap(
                    spacing: Spacing.two,
                    runSpacing: Spacing.two,
                    children: <Widget>[
                      for (final b in badges)
                        FindrBadge(label: badgeLabel(b, ctx), tone: BadgeTone.confirm),
                      if (card.status == CardStatus.archived) const FindrBadge(label: '已归档'),
                      FindrBadge(
                        label: switch (card.source) {
                          SourceKind.photo => '拍照',
                          SourceKind.voice => '语音',
                          SourceKind.text => '文字',
                        },
                      ),
                    ],
                  ),
                ],
                if (card.ask != null && card.ask!.isNotEmpty) ...<Widget>[
                  const SizedBox(height: Spacing.three),
                  Text(
                    '想确认：${card.ask}',
                    style: TextStyle(fontSize: 13, height: 1.4, color: c.badgeConfirm),
                  ),
                ],
                if (card.pathSuggestion != null && card.pathNames == null) ...<Widget>[
                  const SizedBox(height: Spacing.two),
                  Text(
                    '模型猜的位置：${card.pathSuggestion}',
                    style: TextStyle(fontSize: 12, color: c.textSecondary),
                  ),
                ],
                const SizedBox(height: Spacing.four),
                const SectionTitle('原文'),
                const SizedBox(height: Spacing.two),
                if (card.transcript != null && card.transcript!.isNotEmpty)
                  Text(
                    card.transcript!,
                    style: TextStyle(fontSize: 15, height: 1.55, color: c.text),
                  )
                else
                  Text(
                    card.audioPath != null
                        ? '还没有文字。在下面「卡片文字 → 口述原文」里补一句，这张卡就能解析入库。'
                        : '没有原文。',
                    style: TextStyle(fontSize: 13, height: 1.5, color: c.textMuted),
                  ),
                if (card.audioPath != null) ...<Widget>[
                  const SizedBox(height: Spacing.three),
                  Container(
                    decoration: BoxDecoration(
                      color: c.surfaceAlt,
                      borderRadius: BorderRadius.circular(Radii.md),
                      border: Border.all(color: c.border),
                    ),
                    padding: const EdgeInsets.all(Spacing.three),
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.graphic_eq_rounded, size: 18, color: c.textSecondary),
                        const SizedBox(width: Spacing.two),
                        Expanded(
                          child: Text(
                            '这段录音已存在本地。播放功能随「拍照 / 录音录入」一起接上。',
                            style: TextStyle(fontSize: 11.5, height: 1.4, color: c.textSecondary),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (images.isNotEmpty) ...<Widget>[
                  const SizedBox(height: Spacing.four),
                  SectionTitle('照片', hint: '${images.length} 张'),
                  const SizedBox(height: Spacing.two),
                  SizedBox(
                    height: 96,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: images.length,
                      separatorBuilder: (_, _) => const SizedBox(width: Spacing.two),
                      itemBuilder: (_, i) => GestureDetector(
                        onTap: () => openImageViewer(context, images[i]),
                        child: MediaThumb(relPath: images[i], size: 96, fallbackIcon: '📷'),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // ── 待办（只在真有东西可做时出现） ─────────────────
          if (card.retryCount > 0 ||
              card.status == CardStatus.pending ||
              card.status == CardStatus.pendingTranscript ||
              card.needsOrganize)
            Panel(
              title: '待办',
              hint: '解决后角标即消失',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (card.needsOrganize)
                    FindrButton(
                      title: '重新整理',
                      loading: _busy,
                      onPressed: () => _run((d) => reorganizeCard(d, card.id), '重新整理'),
                    ),
                  if (canReanalyze(card, ctx)) ...<Widget>[
                    const SizedBox(height: Spacing.two),
                    FindrButton(
                      title: '补分析图片',
                      variant: FindrButtonVariant.secondary,
                      loading: _busy,
                      onPressed: () => _confirmReanalyze(card),
                    ),
                  ],
                  if (!card.needsOrganize && card.status == CardStatus.active) ...<Widget>[
                    const SizedBox(height: Spacing.two),
                    FindrButton(
                      title: '重新生成描述',
                      variant: FindrButtonVariant.secondary,
                      loading: _busy,
                      onPressed: () => _run((d) => regenerateDesc(d, card.id), '重新生成描述'),
                    ),
                  ],
                  if (card.status == CardStatus.pending ||
                      card.status == CardStatus.pendingTranscript) ...<Widget>[
                    const SizedBox(height: Spacing.two),
                    FindrButton(
                      title: '立即重试一次',
                      variant: FindrButtonVariant.secondary,
                      loading: _busy,
                      onPressed: () => _run(
                        (d) => advanceCard(d, card.id, vision: currentVision(rt)),
                        '重试',
                      ),
                    ),
                  ],
                  if (card.lastError != null) ...<Widget>[
                    const SizedBox(height: Spacing.two),
                    Text(
                      '上次错误：${card.lastError}',
                      style: TextStyle(fontSize: 11.5, height: 1.4, color: c.textMuted),
                    ),
                  ],
                ],
              ),
            ),

          // ── 分类与位置 ───────────────────────────────────
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const SectionTitle('分类', hint: 'AI 自动归类，可随时更正'),
                const SizedBox(height: Spacing.three),
                Wrap(
                  spacing: Spacing.two,
                  runSpacing: Spacing.two,
                  children: <Widget>[
                    if (categories.isEmpty)
                      Text(
                        '还没有分类。去「设置 → 分类」建一个。',
                        style: TextStyle(fontSize: 12, color: c.textMuted),
                      ),
                    for (final cat in categories)
                      FindrChip(
                        dense: true,
                        label: '${cat.emoji ?? ''}${cat.name}',
                        active: card.categoryId == cat.id,
                        // 再点一次即取消归类（用户可能只是归错了想摘掉）
                        onPressed: () => _patch(
                          CardPatch(categoryId: card.categoryId == cat.id ? null : cat.id),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: Spacing.four),
                const SectionTitle('位置', hint: '内容里说了就自动记，没说不强求'),
                const SizedBox(height: Spacing.two),
                ListRow(
                  title: card.pathNames ?? '还没记录位置',
                  subtitle: card.pathNames != null
                      ? (card.pathMatched == false
                            ? '解析时新建的位置，不对可以改'
                            : '解析时自动记录；点这里可以改到别处')
                      : '解析这条卡片时如果提到了位置会自动记录；也可以现在手动选一个',
                  onTap: () => _pickLocation(locations),
                  right: Text(
                    card.pathNames != null ? '修改' : '选择',
                    style: TextStyle(fontSize: 13, color: c.record),
                  ),
                ),
                if (card.pathNames != null) ...<Widget>[
                  const SizedBox(height: Spacing.two),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FindrButton(
                      title: '清除位置',
                      variant: FindrButtonVariant.ghost,
                      compact: true,
                      expand: false,
                      onPressed: () => _patch(
                        const CardPatch(pathIds: null, pathNames: null),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // ── 卡片文字 ─────────────────────────────────────
          Panel(
            title: '卡片文字',
            hint: '改完可以重新生成描述',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                FindrField(
                  label: '口述原文',
                  controller: _transcript,
                  multiline: true,
                  hint: '顶部「原文」显示的就是这里的内容',
                  // 与 RN 同口径：改一下就落库。SQLite 本地写入是微秒级，
                  // 而「编辑丢了」是不可接受的 —— 宁可多写几次。
                  onChanged: (v) => _patch(CardPatch(transcript: v)),
                ),
                const SizedBox(height: Spacing.four),
                FindrField(
                  label: '描述',
                  controller: _desc,
                  multiline: true,
                  onChanged: (v) => _patch(CardPatch(desc: v)),
                ),
                const SizedBox(height: Spacing.four),
                FindrField(
                  label: '实体名',
                  controller: _entity,
                  placeholder: '规范名称，如「备用手电筒」',
                  onChanged: (v) => _patch(CardPatch(entity: v)),
                ),
                const SizedBox(height: Spacing.four),
                FindrField(
                  label: '标签',
                  controller: _tags,
                  placeholder: '用、或逗号分隔',
                  onChanged: (v) => _patch(
                    CardPatch(
                      tags: v
                          .split(RegExp(r'[、,，\s]+'))
                          .map((s) => s.trim())
                          .where((s) => s.isNotEmpty)
                          .toList(),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── 步骤（按内容出现） ───────────────────────────
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                GestureDetector(
                  onTap: () => setState(() => _stepsOpen = !_stepsOpen),
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '步骤${steps.isEmpty ? '（没有）' : '（${steps.length}）'}',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: c.textSecondary,
                          ),
                        ),
                      ),
                      Text(
                        showSteps ? '收起' : '展开',
                        style: TextStyle(fontSize: 13, color: c.record),
                      ),
                    ],
                  ),
                ),
                if (showSteps) ...<Widget>[
                  const SizedBox(height: Spacing.three),
                  for (int i = 0; i < steps.length; i++)
                    _StepRow(
                      step: steps[i],
                      onToggle: () => _patch(
                        CardPatch(
                          steps: <StepItem>[
                            for (int j = 0; j < steps.length; j++)
                              j == i
                                  ? StepItem(text: steps[i].text, done: !steps[i].done)
                                  : steps[j],
                          ],
                        ),
                      ),
                      onUp: i == 0 ? null : () => _moveStep(steps, i, -1),
                      onDown: i == steps.length - 1 ? null : () => _moveStep(steps, i, 1),
                      onDelete: () {
                        final next = <StepItem>[...steps]..removeAt(i);
                        _patch(CardPatch(steps: next.isEmpty ? null : next));
                      },
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FindrButton(
                      title: '＋ 添加一步',
                      variant: FindrButtonVariant.ghost,
                      compact: true,
                      expand: false,
                      onPressed: () => _patch(
                        CardPatch(
                          steps: <StepItem>[
                            ...steps,
                            StepItem(text: '第 ${steps.length + 1} 步', done: false),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // ── 其他操作 ─────────────────────────────────────
          Panel(
            title: '其他操作',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                FindrButton(
                  title: card.status == CardStatus.archived ? '恢复到记忆流' : '归档（移出检索）',
                  variant: FindrButtonVariant.secondary,
                  onPressed: () {
                    final rt2 = ref.read(runtimeProvider).value;
                    if (rt2 == null) return;
                    setCardStatus(
                      rt2.driver,
                      card.id,
                      card.status == CardStatus.archived
                          ? CardStatus.active
                          : CardStatus.archived,
                      DateTime.now(),
                    );
                    _reload();
                  },
                ),
                const SizedBox(height: Spacing.two),
                FindrButton(
                  title: '删除卡片',
                  variant: FindrButtonVariant.danger,
                  onPressed: _delete,
                ),
              ],
            ),
          ),

          Center(
            child: Text(
              card.id,
              style: TextStyle(fontSize: 11, color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  void _moveStep(List<StepItem> steps, int i, int delta) {
    final j = i + delta;
    if (j < 0 || j >= steps.length) return;
    final next = <StepItem>[...steps];
    final tmp = next[i];
    next[i] = next[j];
    next[j] = tmp;
    _patch(CardPatch(steps: next));
  }

  Future<void> _confirmReanalyze(MemoryCard card) async {
    final c = FindrColors.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: Text('补分析会覆盖结构化字段', style: TextStyle(fontSize: 16, color: c.text)),
        content: Text(
          '模型重跑后，实体名、位置、标签等都会按图片重写。',
          style: TextStyle(fontSize: 13, height: 1.5, color: c.textSecondary),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: c.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('继续', style: TextStyle(color: c.danger)),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await _run((d) => reanalyzeCard(d, card.id), '补分析');
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.step,
    required this.onToggle,
    required this.onDelete,
    this.onUp,
    this.onDown,
  });

  final StepItem step;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final VoidCallback? onUp;
  final VoidCallback? onDown;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.two),
      child: Row(
        children: <Widget>[
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.all(Spacing.one),
              child: Icon(
                step.done ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                size: 20,
                color: step.done ? c.success : c.textMuted,
              ),
            ),
          ),
          const SizedBox(width: Spacing.two),
          Expanded(
            child: Text(
              step.text,
              style: TextStyle(
                fontSize: 14,
                height: 1.4,
                color: c.text,
                decoration: step.done ? TextDecoration.lineThrough : null,
                decorationColor: c.textMuted,
              ),
            ),
          ),
          _StepIcon(icon: Icons.keyboard_arrow_up_rounded, onTap: onUp),
          _StepIcon(icon: Icons.keyboard_arrow_down_rounded, onTap: onDown),
          _StepIcon(icon: Icons.close_rounded, onTap: onDelete),
        ],
      ),
    );
  }
}

class _StepIcon extends StatelessWidget {
  const _StepIcon({required this.icon, this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    if (onTap == null) return const SizedBox(width: 30);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: SizedBox(width: 30, height: 30, child: Icon(icon, size: 18, color: c.textMuted)),
    );
  }
}
