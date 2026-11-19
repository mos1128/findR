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
/// 3. **检索是独立一页**（[SearchScreen]）。首页顶部那个框只是入口，
///    点进去才有输入框、最近搜索与结果 —— 这一屏放不下第四块内容。
/// 4. **卡片的长按是管理入口**：归档 / 删除 / 多选都从长按进来，详情页只管信息。
library;

import 'dart:async';

import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../capture/composer.dart';
import '../capture/submit.dart';
import '../platform/inbound_share.dart';
import '../platform/media.dart';
import '../platform/media_gc.dart';
import '../platform/network.dart';
import '../platform/runtime.dart';
import '../state/memory_stream.dart';
import '../state/update_check.dart';
import '../theme/tokens.dart';
import '../ui/card_row.dart';
import '../ui/haptics.dart';
import '../ui/kit.dart';
import 'card_detail_screen.dart';
import 'search_screen.dart';
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
  ProviderSubscription<AsyncValue<bool>>? _onlineSub;
  ProviderSubscription<AsyncValue<RuntimeState>>? _runtimeGcSub;

  /// 管理模式：卡片点一下是选中，不再进详情。
  bool _managing = false;
  final Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 网络恢复 ⇒ 立刻补跑待整理队列。
    // 订阅连接状态本身几乎零成本（插件是事件流）；不订阅的话，用户只能切后台再切回来。
    _onlineSub = ref.listenManual(onlineProvider, (prev, next) {
      if (prev?.value == false && next.value == true) {
        unawaited(_drainQueue());
      }
    });
    // 运行时（库连接）就绪后再扫孤儿媒体；首帧时它往往还在异步打开。
    // 只跑一次：拿到第一个可用快照就退订。
    _runtimeGcSub = ref.listenManual(runtimeProvider, (prev, next) {
      final rt = next.value;
      if (rt == null) return;
      _runtimeGcSub?.close();
      _runtimeGcSub = null;
      try {
        collectOrphanMedia(rt.driver);
      } catch (_) {
        // 回收失败不影响任何功能
      }
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _runtimeGcSub?.close();
    _onlineSub?.close();
    WidgetsBinding.instance.removeObserver(this);
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
      // 只补跑队列，不重搜当前检索 —— 回前台/联网不该再发一次 P2/P4。
      await ref.read(memoryStreamProvider.notifier).drainQueue();
    } catch (_) {
      // 补跑失败不改库里的素材；卡片自己会带「重试中」角标
    }
  }

  /// 录完一条：**先落盘**（草稿立即可见），再在后台推进解析队列。
  ///
  /// 「先落盘」是硬顺序：图片/录音在这里才进媒体目录，卡片行随后插入。
  /// 中间任何一步失败都只会让这次录入白费，**不会**留下一条有记录没素材的卡片
  /// （见 `capture/submit.dart` 的文件头）。
  Future<bool> _submit(ComposerPayload payload) async {
    final rt = ref.read(runtimeProvider).value;
    if (rt == null) {
      _toast('尚未就绪，请稍候');
      return false;
    }
    try {
      await persistCapture(
        rt.driver,
        CaptureSubmission(
          text: payload.text,
          photos: payload.photos,
          audio: payload.audio,
          attachments: payload.attachments,
          vision: payload.vision,
        ),
      );
    } catch (e) {
      _toast('保存失败：$e');
      // 返回 false：Composer 会保留用户输入的全部素材
      return false;
    }
    // 草稿立刻出现在流里 —— 这是「先落盘、素材永不丢失」给用户看的证据。
    await ref.read(memoryStreamProvider.notifier).reload();
    // 队列要跑模型调用，几秒到几十秒；**不能让录入条一直转**，所以放后台。
    unawaited(_advanceAfterSubmit());
    return true;
  }

  Future<void> _advanceAfterSubmit() async {
    try {
      // 重读运行时：设置可能刚变过，`rt.capture` 还是旧快照
      await ref.read(runtimeProvider.notifier).refresh();
      await ref.read(memoryStreamProvider.notifier).drainQueue();
    } catch (_) {
      // 同上：失败只是留在「待解析」，素材没丢
    }
  }

  void _toast(String message) => showFindrToast(context, message);

  Future<void> _openCard(String id) async {
    // 只是打开看一眼就返回，不该重跑检索（更不该再发一次模型请求）。
    // 详情页在用户真的改了东西时才置 true。
    final changed = ValueNotifier<bool>(false);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CardDetailScreen(cardId: id, changed: changed),
      ),
    );
    final didChange = changed.value;
    changed.dispose();
    if (didChange) await ref.read(memoryStreamProvider.notifier).reload();
  }

  void _openSearch() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SearchScreen()));
  }

  // ── 管理：归档 / 删除 / 多选 ─────────────────────────────────

  void _enterManage([String? first]) {
    hapticHold();
    setState(() {
      _managing = true;
      _selected.clear();
      if (first != null) _selected.add(first);
    });
  }

  void _exitManage() {
    setState(() {
      _managing = false;
      _selected.clear();
    });
  }

  void _toggle(String id) {
    hapticTap();
    setState(() {
      if (!_selected.add(id)) _selected.remove(id);
    });
  }

  void _toggleAll(List<MemoryCard> cards) {
    hapticTap();
    setState(() {
      if (_selected.length == cards.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(cards.map((c) => c.id));
      }
    });
  }

  /// 长按卡片：三个动作都在这里，详情页不再放归档与删除。
  Future<void> _cardActions(MemoryCard card) async {
    hapticHold();
    final c = FindrColors.of(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.two,
            Spacing.three,
            Spacing.two,
            Spacing.two,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.two,
                  0,
                  Spacing.two,
                  Spacing.two,
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        cardTitleOf(card),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: c.textMuted),
                      ),
                    ),
                  ],
                ),
              ),
              ListRow(
                title: '归档',
                subtitle: '移出记忆流与检索，可在「设置 → 数据与维护 → 已归档」找回',
                leading: Icon(
                  Icons.inventory_2_outlined,
                  size: 20,
                  color: c.textSecondary,
                ),
                onTap: () => Navigator.of(ctx).pop('archive'),
              ),
              ListRow(
                title: '多选',
                subtitle: '批量归档或删除',
                leading: Icon(
                  Icons.checklist_rounded,
                  size: 20,
                  color: c.textSecondary,
                ),
                onTap: () => Navigator.of(ctx).pop('select'),
              ),
              ListRow(
                title: '删除',
                subtitle: '图片和录音会一起删掉',
                leading: Icon(
                  Icons.delete_outline_rounded,
                  size: 20,
                  color: c.danger,
                ),
                onTap: () => Navigator.of(ctx).pop('delete'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'archive':
        await _archive(<MemoryCard>[card]);
      case 'select':
        _enterManage(card.id);
      case 'delete':
        await _delete(<MemoryCard>[card]);
    }
  }

  Future<void> _archive(List<MemoryCard> cards) async {
    final rt = ref.read(runtimeProvider).value;
    if (rt == null || cards.isEmpty) return;
    final now = DateTime.now();
    try {
      for (final card in cards) {
        setCardStatus(rt.driver, card.id, CardStatus.archived, now);
      }
    } catch (e) {
      _toast('归档失败：${plainError(e)}');
      return;
    }
    if (_managing) _exitManage();
    await ref.read(memoryStreamProvider.notifier).reload();
    _toast(
      cards.length == 1
          ? '已归档，可在「设置 → 数据与维护 → 已归档」找回'
          : '已归档 ${cards.length} 张，可在「设置 → 数据与维护 → 已归档」找回',
    );
  }

  Future<void> _delete(List<MemoryCard> cards) async {
    if (cards.isEmpty) return;
    final rt = ref.read(runtimeProvider).value;
    if (rt == null) return;
    final c = FindrColors.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: Text(
          cards.length == 1 ? '删除这张卡片？' : '删除这 ${cards.length} 张卡片？',
          style: TextStyle(fontSize: 16, color: c.text),
        ),
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
    if (yes != true || !mounted) return;
    try {
      for (final card in cards) {
        // 先删行，再清卡片目录与录音：附件不进 DB（详情页按目录扫描），
        // 整目录删一次就够。半路失败最多留下孤儿文件，下次启动的媒体回收会处理。
        deleteCard(rt.driver, card.id);
        try {
          removeCardFiles(card);
        } catch (_) {
          // 删不掉就交给孤儿媒体回收
        }
      }
    } catch (e) {
      _toast('删除失败：${plainError(e)}');
      return;
    }
    if (_managing) _exitManage();
    await ref.read(memoryStreamProvider.notifier).reload();
    _toast(cards.length == 1 ? '已删除' : '已删除 ${cards.length} 张');
  }

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final stream = ref.watch(memoryStreamProvider);
    final rtAsync = ref.watch(runtimeProvider);

    final rt = rtAsync.value;
    final llmReady = llmConfigured(rt?.llm);
    final state = stream.value;
    final cards = state?.cards ?? const <MemoryCard>[];
    // 启动时静默检查过更新：有新版本就在设置入口打红点
    final hasUpdate = ref.watch(updateHintProvider).value != null;

    // 管理模式里返回键先退管理，不要一步退出首页
    return PopScope(
      canPop: !_managing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _managing) _exitManage();
      },
      child: Scaffold(
        backgroundColor: c.background,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: <Widget>[
              _SearchBar(
                onSearch: _openSearch,
                onSettings: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SettingsScreen(),
                  ),
                ),
                categories: state?.categories ?? const <Category>[],
                categoryFilter: state?.categoryFilter,
                onCategory: (id) =>
                    ref.read(memoryStreamProvider.notifier).setCategory(id),
                onNewCategory: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const CategoriesScreen(),
                  ),
                ),
                llmReady: llmReady,
                hasUpdate: hasUpdate,
              ),
              Expanded(
                child: _buildFlow(
                  context,
                  stream,
                  rtAsync,
                  cards,
                  managing: _managing,
                ),
              ),
              if (_managing)
                _ManageBar(
                  selected: _selected.length,
                  total: cards.length,
                  onCancel: _exitManage,
                  onToggleAll: () => _toggleAll(cards),
                  onArchive: () => unawaited(
                    _archive(
                      cards.where((c) => _selected.contains(c.id)).toList(),
                    ),
                  ),
                  onDelete: () => unawaited(
                    _delete(
                      cards.where((c) => _selected.contains(c.id)).toList(),
                    ),
                  ),
                )
              else
                Composer(
                  busy: false,
                  // 别处「分享到 Findr」进来的内容预填在这里
                  inbound: ref.watch(inboundShareProvider),
                  // 「记」这一侧只报**非模型类**的降级原因。没配模型已在顶部提示条里说过，
                  // 这里再说一遍只会让同一屏出现两段几乎一样的话。
                  notice: _composerNotice(),
                  // 图片分析开关：模型能力 + 设置里的默认值（`effectiveVision` 已把两个因素合起来）
                  visionCapable: visionSupported(rt?.llm),
                  visionDefault: rt == null ? true : currentVision(rt),
                  onSubmit: _submit,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 录入坞上方的提示条：只报「离线」这一种即时降级。
  ///
  /// 没配 ASR 不在这里提示 —— 语音会先落盘，设置页的「语音识别」行会显示未配置。
  Widget? _composerNotice() {
    final online = ref.watch(onlineProvider).value ?? true;
    if (!online) {
      return const Notice(text: '无网络。先记下来，联网后自动解析。', tone: NoticeTone.warn);
    }
    return null;
  }

  Widget _buildFlow(
    BuildContext context,
    AsyncValue<MemoryStreamState> stream,
    AsyncValue<RuntimeState> rtAsync,
    List<MemoryCard> cards, {
    required bool managing,
  }) {
    final s = stream.value;

    if (rtAsync.isLoading && s == null) {
      return const Center(child: CircularProgressIndicator());
    }
    // 数据库都没打开的话其余界面全是空转；必须让用户看得见原因
    final fatal = rtAsync.error != null ? '$rtAsync.error' : s?.loadError;
    if (fatal != null && s == null) {
      return ScreenBody.column(
        children: <Widget>[
          Notice(title: '数据库无法打开', text: fatal, tone: NoticeTone.danger),
        ],
      );
    }

    final byId = <String, Category>{
      for (final cat in s?.categories ?? const <Category>[]) cat.id: cat,
    };

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
              if (s?.loadError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.three),
                  child: Notice(
                    title: '读取卡片失败',
                    text: s!.loadError!,
                    tone: NoticeTone.danger,
                  ),
                ),
            ],
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.four,
            0,
            Spacing.four,
            Spacing.three,
          ),
          sliver: SliverList.separated(
            itemCount: cards.length,
            separatorBuilder: (_, _) => const SizedBox(height: Spacing.three),
            itemBuilder: (_, i) {
              // 懒加载：列表末尾那一项被构建时再取下一页（一次 100 条）。
              if (i == cards.length - 1 && (s?.hasMore ?? false)) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  unawaited(ref.read(memoryStreamProvider.notifier).loadMore());
                });
              }
              final card = cards[i];
              final cat = card.categoryId == null
                  ? null
                  : byId[card.categoryId];
              final picked = _selected.contains(card.id);
              return CardRow(
                card: card,
                ctx: _badgeCtx(),
                categoryName: cat?.name,
                categoryEmoji: cat?.emoji,
                leading: managing ? _PickMark(picked: picked) : null,
                onTap: managing
                    ? () => _toggle(card.id)
                    : () => unawaited(_openCard(card.id)),
                onLongPress: managing
                    ? () => _toggle(card.id)
                    : () => unawaited(_cardActions(card)),
              );
            },
          ),
        ),
        if (s?.loadingMore ?? false)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(bottom: Spacing.three),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.four,
            0,
            Spacing.four,
            Spacing.five,
          ),
          sliver: SliverList.list(
            children: <Widget>[
              if (!managing && cards.isEmpty)
                const EmptyState(
                  icon: Icons.inbox_outlined,
                  title: '还没有记忆',
                  hint: '用底部的输入框记下第一笔',
                ),
            ],
          ),
        ),
      ],
    );
  }

  BadgeContext _badgeCtx() {
    final rt = ref.read(runtimeProvider).value;
    return BadgeContext(
      visionSupported: visionSupported(rt?.llm),
      asrConfigured: rt?.asr != null,
    );
  }
}

/// 管理模式下卡片行首的选择圈。
class _PickMark extends StatelessWidget {
  const _PickMark({required this.picked});

  final bool picked;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    return Container(
      width: 20,
      height: 20,
      margin: const EdgeInsets.only(top: 2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: picked ? c.record : Colors.transparent,
        border: Border.all(
          color: picked ? c.record : c.border,
          width: picked ? 0 : 1.5,
        ),
      ),
      child: picked
          ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
          : null,
    );
  }
}

/// 管理模式底部条：替代录入坞，把批量动作摆在手边。
class _ManageBar extends StatelessWidget {
  const _ManageBar({
    required this.selected,
    required this.total,
    required this.onCancel,
    required this.onToggleAll,
    required this.onArchive,
    required this.onDelete,
  });

  final int selected;
  final int total;
  final VoidCallback onCancel;
  final VoidCallback onToggleAll;
  final VoidCallback onArchive;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final any = selected > 0;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.four,
            Spacing.two,
            Spacing.four,
            Spacing.two,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(
                    '已选 $selected / $total 张',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: c.textSecondary,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: onToggleAll,
                    child: Text(
                      selected == total ? '取消全选' : '全选',
                      style: TextStyle(
                        fontSize: 13,
                        color: c.record,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: Spacing.four),
                  GestureDetector(
                    onTap: onCancel,
                    child: Text(
                      '完成',
                      style: TextStyle(fontSize: 13, color: c.textMuted),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.two),
              Row(
                children: <Widget>[
                  Expanded(
                    child: FindrButton(
                      title: '归档',
                      variant: FindrButtonVariant.secondary,
                      onPressed: any ? onArchive : null,
                    ),
                  ),
                  const SizedBox(width: Spacing.two),
                  Expanded(
                    // 中性底而不是红底：删除的后果写在确认弹窗里，
                    // 这一条不该是整屏最抢眼的东西（否则每次多选都像在劝你删）
                    child: FindrButton(
                      title: '删除',
                      variant: FindrButtonVariant.secondary,
                      onPressed: any ? onDelete : null,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 顶部「查」区：搜索入口 + 设置入口 + 分类 Chip 栏。
class _SearchBar extends StatefulWidget {
  const _SearchBar({
    required this.onSearch,
    required this.onSettings,
    required this.categories,
    required this.categoryFilter,
    required this.onCategory,
    required this.onNewCategory,
    required this.llmReady,
    required this.hasUpdate,
  });

  final VoidCallback onSearch;
  final VoidCallback onSettings;
  final List<Category> categories;
  final String? categoryFilter;
  final ValueChanged<String?> onCategory;
  final VoidCallback onNewCategory;
  final bool llmReady;

  /// 启动时静默检查发现的新版本 —— 设置入口打红点。
  final bool hasUpdate;

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
                      child: Material(
                        color: c.surfaceSunken,
                        borderRadius: BorderRadius.circular(Radii.pill),
                        child: InkWell(
                          onTap: widget.onSearch,
                          borderRadius: BorderRadius.circular(Radii.pill),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: Spacing.four,
                              vertical: 11,
                            ),
                            child: Row(
                              children: <Widget>[
                                Icon(
                                  Icons.search_rounded,
                                  size: 18,
                                  color: c.search,
                                ),
                                const SizedBox(width: Spacing.two),
                                Text(
                                  '搜索记忆',
                                  style: TextStyle(
                                    fontSize: 14.5,
                                    color: c.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: Spacing.two),
                    Container(
                      decoration: BoxDecoration(
                        color: c.surfaceSunken,
                        borderRadius: BorderRadius.circular(Radii.pill),
                      ),
                      child: Badge(
                        isLabelVisible: widget.hasUpdate,
                        // 红点：和「检查更新」行上的那个点是同一个信号（见 settings_screen）。
                        // 用过品牌蓝（c.record），混在蓝色齿轮里看不出是「有更新」。
                        backgroundColor: c.danger,
                        child: IconButton(
                          onPressed: widget.onSettings,
                          icon: const Icon(Icons.settings_outlined, size: 20),
                          color: c.textSecondary,
                          tooltip: '设置',
                          padding: const EdgeInsets.all(Spacing.two),
                          constraints: const BoxConstraints(
                            minWidth: 42,
                            minHeight: 42,
                          ),
                        ),
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
                                    padding: const EdgeInsets.only(
                                      right: Spacing.two,
                                    ),
                                    itemCount: widget.categories.length + 2,
                                    separatorBuilder: (_, _) =>
                                        const SizedBox(width: Spacing.two),
                                    itemBuilder: (_, i) {
                                      if (i == 0) {
                                        return FindrChip(
                                          label: '全部',
                                          dense: true,
                                          canvas: true,
                                          active: widget.categoryFilter == null,
                                          onPressed: () =>
                                              widget.onCategory(null),
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
                                        onPressed: () => widget.onCategory(
                                          widget.categoryFilter == cat.id
                                              ? null
                                              : cat.id,
                                        ),
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
                                  borderRadius: BorderRadius.circular(
                                    Radii.pill,
                                  ),
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
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: <Widget>[
                                  Text(
                                    '全部分类（${widget.categories.length}）',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                      color: c.textSecondary,
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: () =>
                                        setState(() => _expanded = false),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: <Widget>[
                                        Text(
                                          '收起',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: c.textMuted,
                                          ),
                                        ),
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
                                      onPressed: () => widget.onCategory(
                                        widget.categoryFilter == cat.id
                                            ? null
                                            : cat.id,
                                      ),
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
                      MaterialPageRoute<void>(
                        builder: (_) => const ProviderSettingsScreen(),
                      ),
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Spacing.three,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: c.surfaceAlt.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(Radii.pill),
                      ),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            Icons.info_outline_rounded,
                            size: 14,
                            color: c.textMuted,
                          ),
                          const SizedBox(width: Spacing.two),
                          Expanded(
                            child: Text(
                              '尚未配置模型',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: c.textSecondary,
                              ),
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
