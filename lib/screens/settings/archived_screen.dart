/// 已归档的卡片。
///
/// 归档 = **移出记忆流与检索，但没删**（`listCards` 默认不返回 archived，
/// 检索在 SQL 里硬过滤 `active`）。所以这一页是归档唯一的出口：
/// 没有它，用户点一下「归档」就再也找不回这张卡了。
library;

import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/media.dart';
import '../../platform/runtime.dart';
import '../../theme/tokens.dart';
import '../../ui/card_row.dart';
import '../../ui/kit.dart';
import '../../ui/runtime_fallback.dart';
import '../card_detail_screen.dart';

class ArchivedScreen extends ConsumerStatefulWidget {
  const ArchivedScreen({super.key});

  @override
  ConsumerState<ArchivedScreen> createState() => _ArchivedScreenState();
}

class _ArchivedScreenState extends ConsumerState<ArchivedScreen> {
  /// 归档状态是库里的值，改完 `setState` 就会重读（和分类页一个路子）。
  RuntimeState get _rt {
    final v = ref.read(runtimeProvider).value;
    if (v == null) throw StateError('运行时尚未就绪');
    return v;
  }

  void _restore(MemoryCard card) {
    setCardStatus(_rt.driver, card.id, CardStatus.active, DateTime.now());
    // 首页读的是同一个 provider，刷新一下，恢复的卡立刻回到流里
    ref.read(runtimeProvider.notifier).refresh();
    setState(() {});
    showFindrToast(context, '已恢复到记忆流');
  }

  Future<void> _delete(MemoryCard card) async {
    final c = FindrColors.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: Text('彻底删除这张卡片？', style: TextStyle(fontSize: 16, color: c.text)),
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
    // 先删行，再清目录：附件不进 DB（详情页按目录扫描），整目录删一次就够。
    // 删失败或进程被杀最多留下孤儿文件，下次启动的媒体回收会处理。
    deleteCard(rt.driver, card.id);
    try {
      removeCardFiles(card);
    } catch (_) {
      // 删不掉就交给孤儿媒体回收
    }
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final runtimeState = ref.watch(runtimeProvider);
    final rt = runtimeState.value;
    if (rt == null) {
      return RuntimeFallback(title: '已归档', state: runtimeState);
    }
    final cards = listCards(
      rt.driver,
      const ListCardsOptions(statuses: <CardStatus>[CardStatus.archived]),
    );

    return Scaffold(
      appBar: FindrTopBar(title: '已归档'),
      body: ScreenBody.column(
        padding: const EdgeInsets.fromLTRB(
          Spacing.four,
          Spacing.four,
          Spacing.four,
          Spacing.six,
        ),
        children: <Widget>[
          if (cards.isEmpty)
            const EmptyState(
              icon: Icons.inventory_2_outlined,
              title: '没有归档的卡片',
              hint: '在记忆流里长按一张卡片，选「归档」。',
            )
          else
            Panel(
              // 计数放在 hint 里：它是会变的状态，不是说明
              title: '已归档',
              hint: '${cards.length} 张',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (int i = 0; i < cards.length; i++) ...<Widget>[
                    if (i > 0) const FindrDivider(),
                    ListRow(
                      title: cardTitleOf(cards[i]),
                      subtitle: cardTimeLabel(cards[i].createdAt),
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                CardDetailScreen(cardId: cards[i].id),
                          ),
                        );
                        if (mounted) setState(() {});
                      },
                      right: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          IconButton(
                            onPressed: () => _restore(cards[i]),
                            icon: const Icon(Icons.restore_rounded, size: 20),
                            color: c.record,
                            tooltip: '恢复到记忆流',
                          ),
                          IconButton(
                            onPressed: () => _delete(cards[i]),
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 20,
                            ),
                            color: c.danger,
                            tooltip: '彻底删除',
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}
