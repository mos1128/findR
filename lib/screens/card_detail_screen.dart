/// 卡片详情。
///
/// **首屏 = 用户自己录进来的原始素材：原文 → 录音 → 照片。**
/// **顺序是硬约束**：先素材，后编辑，最后才是归档/删除。
/// 反过来的话，用户点进来第一眼看不到「我记了什么」，只看到一堆分类/状态选择器（真机反馈）。
///
/// 录音在这里**能听**（不是只显示一个文件路径）—— 见 `ui/audio_player.dart`。
library;

import 'dart:async';
import 'dart:io';

import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../platform/app_paths.dart';
import '../platform/media.dart';
import '../platform/runtime.dart';
import '../theme/tokens.dart';
import '../ui/audio_player.dart';
import '../ui/card_row.dart';
import '../ui/kit.dart';
import '../ui/media_view.dart';
import 'settings/categories_screen.dart';

class CardDetailScreen extends ConsumerStatefulWidget {
  const CardDetailScreen({super.key, required this.cardId, this.changed});

  final String cardId;

  /// 用户真的改过东西（文本、分类、位置、步骤、归档、AI 操作、删除）时置 true。
  /// 调用方据此决定要不要重跑检索；只是打开看一眼不算改。
  final ValueNotifier<bool>? changed;

  @override
  ConsumerState<CardDetailScreen> createState() => _CardDetailScreenState();
}

class _CardDetailScreenState extends ConsumerState<CardDetailScreen> {
  /// 写库之后 `++` 一下强制重读。
  int _tick = 0;

  /// 「步骤」按内容出现：有步骤时自动展开，没有则收起 —— 多数记忆本来就没有步骤。
  bool _stepsOpen = false;
  bool _categoriesExpanded = false;

  bool _busy = false;
  bool _editorsReady = false;
  bool _dirtyText = false;
  bool _staleCleanupScheduled = false;
  _ActionResult? _actionResult;

  void _markChanged() => widget.changed?.value = true;

  /// 输入防抖：停止打字 400ms 后落库一次。
  /// 逐键写库会把「敲 100 个字」变成「100 次 UPDATE + 100 次整屏重建」。
  Timer? _saveTimer;

  final _transcript = TextEditingController();
  final _desc = TextEditingController();
  final _entity = TextEditingController();
  final _tags = TextEditingController();

  @override
  void dispose() {
    _saveTimer?.cancel();
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

    // 清理历史遗留：对已经激活的正常卡片，若还残留旧的 lastError 或 retryCount，落库清除它。
    // ⚠️ 不能直接在 build() 里写库；等这一帧画完再写。
    if (card.status == CardStatus.active &&
        !card.needsOrganize &&
        (card.lastError != null || card.retryCount > 0) &&
        !_staleCleanupScheduled) {
      _staleCleanupScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final rt = ref.read(runtimeProvider).value;
        if (rt == null) return;
        updateCardFields(
          rt.driver,
          widget.cardId,
          const CardPatch(lastError: null),
          DateTime.now(),
        );
      });
    }
  }

  void _patch(CardPatch patch) {
    final rt = ref.read(runtimeProvider).value;
    if (rt == null) return;
    updateCardFields(rt.driver, widget.cardId, patch, DateTime.now());
    _markChanged();
    setState(() => _tick++);
  }

  /// 打字期间只排一次延迟保存，不逐键写库。
  void _scheduleSave() {
    if (!_editorsReady) return;
    _dirtyText = true;
    _markChanged();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _flushEditors);
  }

  /// 立即把四个文本框写回库。离开页面、跑 AI 动作前都会调它。
  ///
  /// **只有真的改过文本才写**：打开卡片看一眼再返回，不应该触发一次 UPDATE。
  void _flushEditors() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!_editorsReady || !_dirtyText) return;
    final rt = ref.read(runtimeProvider).value;
    if (rt == null) return;
    try {
      updateCardFields(
        rt.driver,
        widget.cardId,
        CardPatch(
          entity: _entity.text,
          desc: _desc.text,
          transcript: _transcript.text,
          tags: _tags.text
              .split(RegExp(r'[、,，\s]+'))
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList(),
        ),
        DateTime.now(),
      );
      _dirtyText = false;
    } catch (_) {
      // 写失败不打扰用户；下一次编辑或离开时会再写一遍
    }
  }

  void _reload() => setState(() => _tick++);

  void _toast(String message, {bool isError = false}) {
    final c = FindrColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: <Widget>[
              Icon(
                isError ? Icons.error_outline_rounded : Icons.check_circle_rounded,
                size: 20,
                color: isError ? c.danger : c.record,
              ),
              const SizedBox(width: Spacing.two),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: isError
                        ? (isDark ? const Color(0xFFFCA5A5) : const Color(0xFF991B1B))
                        : c.text,
                  ),
                ),
              ),
            ],
          ),
          backgroundColor: isError
              ? (isDark ? const Color(0xFF2C1515) : const Color(0xFFFEF2F2))
              : c.surfaceAlt,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.lg),
            side: BorderSide.none,
          ),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.only(left: 20, right: 20, bottom: 36),
          duration: const Duration(seconds: 4),
          elevation: 4,
        ),
      );
  }

  Future<void> _run(Future<Object?> Function(AdvanceDeps deps) body, String label) async {
    if (!mounted) return;
    // 先把用户刚改的文本落库：下面的 core 调用读的是库里的那份
    _flushEditors();
    setState(() => _busy = true);
    try {
      final rt = ref.read(runtimeProvider).value;
      if (rt == null) return;
      final res = await body(requireDeps(rt));
      // 模型调用期间用户可能已经按返回；结果已写库，界面不能再碰已销毁的对象。
      if (!mounted) return;
      _markChanged();
      _reload();
      final outcome = res is AdvanceResult ? res.outcome : null;
      if (outcome == AdvanceOutcome.retry) {
        final msg = '$label 失败，稍后可以再试一次。';
        setState(() => _actionResult = _ActionResult(message: msg, isError: true));
        _toast(msg, isError: true);
      } else if (res is RegenerateDescResult) {
        if (!res.ok) {
          final msg = '$label 失败：${res.error ?? "未知错误"}';
          setState(() => _actionResult = _ActionResult(message: msg, isError: true));
          _toast(msg, isError: true);
        } else {
          final usageStr = (res.usage != null && res.usage!.total > 0)
              ? ' · 消耗 ${res.usage!.total} tokens'
              : '';
          final msg = '$label 完成$usageStr';
          if (res.card?.desc != null) {
            _desc.text = res.card!.desc!;
          }
          setState(() => _actionResult = _ActionResult(
            message: msg,
            isError: false,
            tokens: res.usage?.total,
          ));
          _toast(msg, isError: false);
        }
      } else if (res is AdvanceResult) {
        if (res.outcome == AdvanceOutcome.activated) {
          final msg = '$label 完成';
          if (res.card.desc != null) _desc.text = res.card.desc!;
          if (res.card.entity != null) _entity.text = res.card.entity!;
          if (res.card.transcript != null) _transcript.text = res.card.transcript!;
          if (res.card.tags != null) _tags.text = res.card.tags!.join('、');
          setState(() => _actionResult = _ActionResult(message: msg, isError: false));
          _toast(msg, isError: false);
        } else {
          final msg = '$label 失败：${res.error ?? "未能成功推进"}';
          setState(() => _actionResult = _ActionResult(message: msg, isError: true));
          _toast(msg, isError: true);
        }
      } else {
        final msg = '$label 完成';
        setState(() => _actionResult = _ActionResult(message: msg, isError: false));
        _toast(msg, isError: false);
      }
    } catch (e) {
      if (!mounted) return;
      final msg = '$label 失败：${plainError(e)}';
      setState(() => _actionResult = _ActionResult(message: msg, isError: true));
      _toast(msg, isError: true);
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
          '图片和录音会一起删掉，不可恢复。',
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
    _saveTimer?.cancel();
    _dirtyText = false;
    // 先删行，再清卡片目录与录音：附件不进 DB（详情页按目录扫描），所以整目录删一次就够，
    // 不必再按 images 逐文件删。删失败或进程半路被杀，最多留下孤儿文件，
    // 下次启动的媒体回收会处理。
    final card = getCard(rt.driver, widget.cardId);
    deleteCard(rt.driver, widget.cardId);
    if (card != null) {
      try {
        removeCardFiles(card);
      } catch (_) {
        // 删不掉就交给孤儿媒体回收
      }
    }
    _markChanged();
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
                  '层级在「设置 → 空间位置树」里改。',
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
    final hasStaleError = card.status == CardStatus.active && !card.needsOrganize;
    final showError = card.lastError != null && !hasStaleError;
    final showProcessingPanel = card.status == CardStatus.pending ||
        card.status == CardStatus.pendingTranscript ||
        card.needsOrganize ||
        canReanalyze(card, ctx) ||
        showError ||
        _actionResult != null;

    List<File> attachmentFiles = const <File>[];
    if (AppPaths.ready && card.createdAt.isNotEmpty) {
      try {
        final date = DateTime.tryParse(card.createdAt) ?? DateTime.now();
        final attachDirRel = 'files/cards/${monthDir(date)}/${card.id}/attachments';
        final attachDir = Directory(AppPaths.abs(attachDirRel));
        if (attachDir.existsSync()) {
          attachmentFiles = attachDir.listSync().whereType<File>().toList();
        }
      } catch (_) {}
    }

    // 任何形式的离开（返回键 / 「完成」/ 系统手势）都先把文本框落库。
    return PopScope(
      onPopInvokedWithResult: (didPop, _) => _flushEditors(),
      child: Scaffold(
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
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: Spacing.three, vertical: Spacing.two),
                    decoration: BoxDecoration(
                      color: c.badgeConfirmBg,
                      borderRadius: BorderRadius.circular(Radii.md),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(Icons.lightbulb_outline_rounded, size: 16, color: c.badgeConfirm),
                        const SizedBox(width: Spacing.two),
                        Expanded(
                          child: Text(
                            '待确认细节：${card.ask}',
                            style: TextStyle(fontSize: 12.5, height: 1.4, color: c.badgeConfirm),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (card.pathSuggestion != null && card.pathNames == null) ...<Widget>[
                  const SizedBox(height: Spacing.two),
                  Text(
                    '推测位置：${card.pathSuggestion}',
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
                        ? '还没转写，可在「详细记录」里补。'
                        : '暂无文字记录。',
                    style: TextStyle(fontSize: 13, height: 1.5, color: c.textMuted),
                  ),
                if (card.audioPath != null) ...<Widget>[
                  const SizedBox(height: Spacing.three),
                  AudioPlayBar(relPath: card.audioPath!, label: '语音记录'),
                ],
                if (images.isNotEmpty) ...<Widget>[
                  const SizedBox(height: Spacing.four),
                  SectionTitle(
                    '照片',
                    hint: '${images.length} 张',
                  ),
                  const SizedBox(height: Spacing.two),
                  SizedBox(
                    height: 96,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: images.length,
                      separatorBuilder: (_, _) => const SizedBox(width: Spacing.two),
                      itemBuilder: (_, i) => GestureDetector(
                        // 整组一起交出去 + 从点的那张开始，才能左右滑着看下一张。
                        onTap: () => openImageViewer(context, images, initialIndex: i),
                        child: MediaThumb(relPath: images[i], size: 96, fallbackIcon: '📷'),
                      ),
                    ),
                  ),
                ],
                if (attachmentFiles.isNotEmpty) ...<Widget>[
                  const SizedBox(height: Spacing.four),
                  SectionTitle(
                    '附件',
                    hint: '${attachmentFiles.length} 个文件',
                  ),
                  const SizedBox(height: Spacing.two),
                  for (final file in attachmentFiles) ...<Widget>[
                    ListRow(
                      leading: Icon(Icons.attach_file_rounded, size: 20, color: c.record),
                      title: file.path.split(Platform.isWindows ? r'\' : '/').last,
                      subtitle: '${(file.lengthSync() / 1024).toStringAsFixed(1)} KB',
                      right: Icon(Icons.share_outlined, size: 18, color: c.textMuted),
                      onTap: () {
                        unawaited(
                          SharePlus.instance.share(
                            ShareParams(
                              files: <XFile>[XFile(file.path)],
                              title: file.path.split(Platform.isWindows ? r'\' : '/').last,
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: Spacing.one),
                  ],
                ],
              ],
            ),
          ),

          // ── 智能处理（有待办、或刚操作完、或可补分析、或有真实异常时展示） ───────────────
          if (showProcessingPanel)
            Panel(
              title: '状态与处理',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (_actionResult != null) ...<Widget>[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Spacing.three,
                        vertical: Spacing.two,
                      ),
                      decoration: BoxDecoration(
                        color: _actionResult!.isError
                            ? c.danger.withValues(alpha: 0.1)
                            : c.record.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(Radii.md),
                      ),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            _actionResult!.isError
                                ? Icons.error_outline_rounded
                                : Icons.check_circle_outline_rounded,
                            size: 18,
                            color: _actionResult!.isError ? c.danger : c.record,
                          ),
                          const SizedBox(width: Spacing.two),
                          Expanded(
                            child: Text(
                              _actionResult!.message,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: _actionResult!.isError ? c.danger : c.record,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: Spacing.two),
                  ],
                  if (card.needsOrganize)
                    FindrButton(
                      title: '重新整理卡片',
                      loading: _busy,
                      onPressed: () => _run((d) => reorganizeCard(d, card.id), '重新整理'),
                    ),
                  if (canReanalyze(card, ctx)) ...<Widget>[
                    if (card.needsOrganize) const SizedBox(height: Spacing.two),
                    FindrButton(
                      title: '分析图片内容',
                      variant: FindrButtonVariant.secondary,
                      loading: _busy,
                      onPressed: () => _confirmReanalyze(card),
                    ),
                  ],
                  if (!card.needsOrganize && card.status == CardStatus.active) ...<Widget>[
                    if (card.needsOrganize || canReanalyze(card, ctx))
                      const SizedBox(height: Spacing.two),
                    FindrButton(
                      title: '重新生成卡片描述',
                      variant: FindrButtonVariant.secondary,
                      loading: _busy,
                      onPressed: () => _run((d) => regenerateDesc(d, card.id), '重新生成描述'),
                    ),
                  ],
                  if (card.status == CardStatus.pending ||
                      card.status == CardStatus.pendingTranscript) ...<Widget>[
                    const SizedBox(height: Spacing.two),
                    FindrButton(
                      title: '重试当前解析任务',
                      variant: FindrButtonVariant.secondary,
                      loading: _busy,
                      onPressed: () => _run(
                        (d) => advanceCard(d, card.id, vision: currentVision(rt)),
                        '重试',
                      ),
                    ),
                  ],
                  if (showError) ...<Widget>[
                    const SizedBox(height: Spacing.two),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Spacing.three,
                        vertical: Spacing.two,
                      ),
                      decoration: BoxDecoration(
                        color: c.danger.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(Radii.md),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Icon(Icons.error_outline_rounded, size: 16, color: c.danger),
                          const SizedBox(width: Spacing.two),
                          Expanded(
                            child: Text(
                              '处理异常：${card.lastError}',
                              style: TextStyle(fontSize: 12, height: 1.4, color: c.danger),
                            ),
                          ),
                        ],
                      ),
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
                const SectionTitle('分类'),
                const SizedBox(height: Spacing.two),
                if (categories.isEmpty)
                  Text(
                    '没有分类。在「设置 → 分类标签」里加。',
                    style: TextStyle(fontSize: 12, color: c.textMuted),
                  )
                else
                  AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeInOutCubic,
                    alignment: Alignment.topCenter,
                    child: !_categoriesExpanded
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
                                      itemCount: categories.length + 1,
                                      separatorBuilder: (_, _) =>
                                          const SizedBox(width: Spacing.two),
                                      itemBuilder: (_, i) {
                                        if (i == categories.length) {
                                          return FindrChip(
                                            label: '＋ 新建分类',
                                            dense: true,
                                            onPressed: () => Navigator.of(context).push(
                                              MaterialPageRoute<void>(
                                                builder: (_) => const CategoriesScreen(),
                                              ),
                                            ),
                                          );
                                        }
                                        final cat = categories[i];
                                        return FindrChip(
                                          label: cat.name,
                                          dense: true,
                                          active: card.categoryId == cat.id,
                                          onPressed: () => _patch(
                                            CardPatch(
                                              categoryId: card.categoryId == cat.id ? null : cat.id,
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: Spacing.two),
                              Material(
                                color: c.surfaceAlt,
                                borderRadius: BorderRadius.circular(Radii.pill),
                                child: InkWell(
                                  onTap: () => setState(() => _categoriesExpanded = true),
                                  borderRadius: BorderRadius.circular(Radii.pill),
                                  child: Container(
                                    width: 32,
                                    height: 32,
                                    alignment: Alignment.center,
                                    child: Icon(
                                      Icons.keyboard_arrow_down_rounded,
                                      size: 20,
                                      color: c.textSecondary,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : Container(
                            decoration: BoxDecoration(
                              color: c.surfaceAlt,
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
                                      '全部分类（${categories.length}）',
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w600,
                                        color: c.textSecondary,
                                      ),
                                    ),
                                    GestureDetector(
                                      onTap: () => setState(() => _categoriesExpanded = false),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: <Widget>[
                                          Text('收起', style: TextStyle(fontSize: 12, color: c.textMuted)),
                                          const SizedBox(width: 2),
                                          Icon(
                                            Icons.keyboard_arrow_up_rounded,
                                            size: 18,
                                            color: c.textMuted,
                                          ),
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
                                    for (final cat in categories)
                                      FindrChip(
                                        dense: true,
                                        label: cat.name,
                                        active: card.categoryId == cat.id,
                                        onPressed: () => _patch(
                                          CardPatch(
                                            categoryId: card.categoryId == cat.id ? null : cat.id,
                                          ),
                                        ),
                                      ),
                                    FindrChip(
                                      label: '＋ 新建分类',
                                      dense: true,
                                      onPressed: () => Navigator.of(context).push(
                                        MaterialPageRoute<void>(
                                          builder: (_) => const CategoriesScreen(),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                  ),
                const SizedBox(height: Spacing.four),
                const SectionTitle('位置'),
                const SizedBox(height: Spacing.two),
                if (card.pathNames != null)
                  Container(
                    padding: const EdgeInsets.all(Spacing.three),
                    decoration: BoxDecoration(
                      color: c.record.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(Radii.md),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: <Widget>[
                        const Text('📍', style: TextStyle(fontSize: 16)),
                        const SizedBox(width: Spacing.two),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                card.pathNames!,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: c.record,
                                ),
                              ),
                              if (card.pathMatched == false) ...<Widget>[
                                const SizedBox(height: 2),
                                Text(
                                  '解析时自动识别的新位置',
                                  style: TextStyle(fontSize: 11.5, color: c.textMuted),
                                ),
                              ],
                            ],
                          ),
                        ),
                        FindrButton(
                          title: '修改',
                          variant: FindrButtonVariant.ghost,
                          compact: true,
                          expand: false,
                          onPressed: () => _pickLocation(locations),
                        ),
                      ],
                    ),
                  )
                else
                  ListRow(
                    title: '暂未指定位置',
                    subtitle: '选所在房间、家具或容器',
                    onTap: () => _pickLocation(locations),
                    right: Text(
                      '选择',
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

          // ── 详细记录 ─────────────────────────────────────
          Panel(
            title: '详细记录',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                FindrField(
                  label: '实体名称（核心标识）',
                  controller: _entity,
                  placeholder: '名称，如「备用钥匙」',
                  onChanged: (_) => _scheduleSave(),
                ),
                const SizedBox(height: Spacing.four),
                FindrField(
                  label: '内容描述',
                  controller: _desc,
                  multiline: true,
                  placeholder: '物品的外观特征、存放细节或备忘内容',
                  onChanged: (_) => _scheduleSave(),
                ),
                const SizedBox(height: Spacing.four),
                FindrField(
                  label: '分类标签',
                  controller: _tags,
                  placeholder: '多个标签用逗号或顿号隔开',
                  onChanged: (_) => _scheduleSave(),
                ),
                const SizedBox(height: Spacing.four),
                FindrField(
                  label: '原始口述 / 转写记录',
                  controller: _transcript,
                  multiline: true,
                  placeholder: '录音识别的原始文本或手录原句',
                  onChanged: (_) => _scheduleSave(),
                ),
                if (!showProcessingPanel &&
                    card.status == CardStatus.active &&
                    !card.needsOrganize) ...<Widget>[
                  const SizedBox(height: Spacing.four),
                  FindrButton(
                    title: '根据修改重新生成卡片描述',
                    variant: FindrButtonVariant.secondary,
                    loading: _busy,
                    onPressed: () => _run((d) => regenerateDesc(d, card.id), '重新生成描述'),
                  ),
                ],
              ],
            ),
          ),

          // ── 步骤清单（按需展示） ───────────────────────────
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
                          steps.isEmpty ? '步骤清单（未添加）' : '步骤清单（${steps.length}）',
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
                      onEdit: () => unawaited(_editStep(index: i)),
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
                      onPressed: () => unawaited(_editStep()),
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
                    _markChanged();
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
        ],
      ),
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

  /// 添加/编辑步骤文字。空输入、越界都直接不写库（见 [stepsWithEditedText]）。
  Future<void> _editStep({int? index}) async {
    final rt = ref.read(runtimeProvider).value;
    if (rt == null) return;
    final steps = getCard(rt.driver, widget.cardId)?.steps ?? const <StepItem>[];
    final initial = index != null && index >= 0 && index < steps.length
        ? steps[index].text
        : '';
    final c = FindrColors.of(context);
    var draft = initial;
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: Text(
          index == null ? '添加步骤' : '编辑步骤',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.text),
        ),
        content: TextFormField(
          initialValue: initial,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          textInputAction: TextInputAction.done,
          onChanged: (value) => draft = value,
          onFieldSubmitted: (value) => Navigator.of(ctx).pop(value),
          style: TextStyle(fontSize: 14.5, color: c.text),
          decoration: InputDecoration(
            hintText: '例如：把护照放进随身包',
            hintStyle: TextStyle(fontSize: 13, color: c.textMuted),
            filled: true,
            fillColor: c.surfaceAlt,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Radii.md),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消', style: TextStyle(color: c.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(draft),
            child: Text(
              '保存',
              style: TextStyle(color: c.record, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    if (!mounted || raw == null) return;
    final latest = getCard(rt.driver, widget.cardId)?.steps ?? const <StepItem>[];
    final next = stepsWithEditedText(latest, index, raw);
    if (next == null) return;
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
          '重跑后，实体、位置、标签都按图片重写。',
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

/// 用户输入 → 新的步骤列表。空输入或越界返回 null，调用方据此不写库。
List<StepItem>? stepsWithEditedText(
  List<StepItem> steps,
  int? index,
  String raw,
) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  if (index == null) {
    return <StepItem>[...steps, StepItem(text: text, done: false)];
  }
  if (index < 0 || index >= steps.length) return null;
  final next = <StepItem>[...steps];
  next[index] = StepItem(text: text, done: next[index].done);
  return next;
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.step,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    this.onUp,
    this.onDown,
  });

  final StepItem step;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onUp;
  final VoidCallback? onDown;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: Spacing.two),
      padding: const EdgeInsets.symmetric(horizontal: Spacing.two, vertical: Spacing.one),
      decoration: BoxDecoration(
        color: step.done ? c.surfaceAlt.withValues(alpha: 0.4) : c.surfaceAlt,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        children: <Widget>[
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(Radii.sm),
            child: Padding(
              padding: const EdgeInsets.all(Spacing.one),
              child: Icon(
                step.done ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                size: 20,
                color: step.done ? c.success : c.textMuted,
              ),
            ),
          ),
          const SizedBox(width: Spacing.two),
          Expanded(
            child: InkWell(
              onTap: onEdit,
              borderRadius: BorderRadius.circular(Radii.sm),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Spacing.one),
                child: Text(
                  step.text,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    color: step.done ? c.textMuted : c.text,
                    decoration: step.done ? TextDecoration.lineThrough : null,
                    decorationColor: c.textMuted,
                  ),
                ),
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

class _ActionResult {
  const _ActionResult({
    required this.message,
    required this.isError,
    this.tokens,
  });

  final String message;
  final bool isError;
  final int? tokens;
}

