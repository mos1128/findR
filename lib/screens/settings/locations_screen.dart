/// 位置树。
///
/// 位置是**检索质量的命脉**：卡片的位置串（`path_names`）是冗余列，
/// 按位置搜索靠的就是它。所以改名之后必须跟一次 `refreshPathNames`，
/// 否则**按旧名字搜不到、按新名字也搜不到**。
library;

import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/runtime.dart';
import '../../theme/tokens.dart';
import '../../ui/kit.dart';

class LocationsScreen extends ConsumerStatefulWidget {
  const LocationsScreen({super.key});

  @override
  ConsumerState<LocationsScreen> createState() => _LocationsScreenState();
}

class _LocationsScreenState extends ConsumerState<LocationsScreen> {
  final _newName = TextEditingController();
  final _renameText = TextEditingController();

  /// 当前选中的父节点（null = 往根上加）。
  String? _parentId;

  RuntimeState get _rt {
    final v = ref.read(runtimeProvider).value;
    if (v == null) throw StateError('运行时还没就绪');
    return v;
  }

  @override
  void dispose() {
    _newName.dispose();
    _renameText.dispose();
    super.dispose();
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

  List<LocationNode> _childrenOf(List<LocationNode> all, String? pid) =>
      all.where((l) => l.parentId == pid).toList()..sort((a, b) => a.sort.compareTo(b.sort));

  void _add() {
    final name = _newName.text.trim();
    if (name.isEmpty) return;
    final all = listLocations(_rt.driver);
    final siblings = _childrenOf(all, _parentId);
    try {
      upsertLocationNode(
        _rt.driver,
        LocationNode(id: makeId(), parentId: _parentId, name: name, sort: siblings.length),
      );
    } catch (e) {
      _toast('添加失败：$e');
      return;
    }
    // 同名同父会被唯一索引忽略 —— 不报错，但也没加上，必须明确告诉用户
    final after = _childrenOf(listLocations(_rt.driver), _parentId);
    if (after.length == siblings.length) {
      _toast('「$name」在这个层级下已经存在了。');
    } else {
      _newName.clear();
    }
    ref.read(runtimeProvider.notifier).refresh();
    setState(() {});
  }

  Future<void> _showRenameDialog(LocationNode node) async {
    _renameText.text = node.name;
    final c = FindrColors.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.lg)),
        title: Text('重命名位置', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.text)),
        content: Container(
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          padding: const EdgeInsets.symmetric(horizontal: Spacing.three),
          child: TextField(
            controller: _renameText,
            autofocus: true,
            style: TextStyle(fontSize: 14, color: c.text),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: '输入新名称',
              hintStyle: TextStyle(fontSize: 13, color: c.textMuted),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onSubmitted: (_) => Navigator.of(ctx).pop(true),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: c.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('保存', style: TextStyle(color: c.record, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok == true) {
      _rename(node.id);
    }
  }

  void _rename(String id) {
    final name = _renameText.text.trim();
    if (name.isEmpty) return;
    renameLocation(_rt.driver, id, name);
    // ⚠️ 改名后同步卡片的冗余位置串，否则按旧名/新名都搜不到
    final changed = refreshPathNames(_rt.driver, DateTime.now());
    _renameText.clear();
    ref.read(runtimeProvider.notifier).refresh();
    setState(() {});
    _toast(changed > 0 ? '已同步：$changed 张卡片的位置串已更新' : '已改名');
  }

  Future<void> _delete(LocationNode node) async {
    final c = FindrColors.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: Text('删除「${node.name}」？', style: TextStyle(fontSize: 16, color: c.text)),
        content: Text(
          '下面还有子位置，或被卡片用着，删不了。',
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
    final res = deleteLocation(_rt.driver, node.id);
    if (!res.ok) {
      _toast(
        res.reason == DeleteLocationRejection.hasChildren
            ? '删不掉：下面还有 ${res.count} 个子位置。'
            : '删不掉：有 ${res.count} 张卡片用了这个位置。',
      );
      return;
    }
    if (_parentId == node.id) _parentId = null;
    ref.read(runtimeProvider.notifier).refresh();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final rt = ref.watch(runtimeProvider).value;
    if (rt == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final all = listLocations(rt.driver);
    final byId = <String, LocationNode>{for (final l in all) l.id: l};
    final parents = <String>[];
    var cursor = _parentId;
    while (cursor != null && byId.containsKey(cursor)) {
      parents.insert(0, byId[cursor]!.name);
      cursor = byId[cursor]!.parentId;
    }

    return Scaffold(
      appBar: FindrTopBar(title: '位置树'),
      body: ScreenBody.column(
        padding: const EdgeInsets.fromLTRB(
          Spacing.four,
          Spacing.four,
          Spacing.four,
          Spacing.six,
        ),
        children: <Widget>[
          Panel(
            title: '当前添加层级',
            hint: '点选下方位置可指定父级',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Wrap(
                  spacing: Spacing.two,
                  runSpacing: Spacing.two,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    FindrChip(
                      dense: true,
                      label: '根位置',
                      active: _parentId == null,
                      onPressed: () => setState(() => _parentId = null),
                    ),
                    for (int i = 0; i < parents.length; i++) ...<Widget>[
                      Icon(Icons.chevron_right_rounded, size: 16, color: c.textMuted),
                      FindrChip(
                        dense: true,
                        label: parents[i],
                        active: i == parents.length - 1,
                        onPressed: i == parents.length - 1
                            ? null
                            : () {
                                var cur = _parentId;
                                for (int k = parents.length - 1; k > i; k--) {
                                  cur = byId[cur]?.parentId;
                                }
                                setState(() => _parentId = cur);
                              },
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: Spacing.three),
                Container(
                  height: 44,
                  decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                  padding: const EdgeInsets.fromLTRB(14, 0, 4, 0),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.add_location_alt_outlined, size: 18, color: c.textMuted),
                      const SizedBox(width: Spacing.two),
                      Expanded(
                        child: TextField(
                          controller: _newName,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _add(),
                          style: TextStyle(fontSize: 14, color: c.text),
                          decoration: InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            hintText: _parentId == null
                                ? '新建根位置，如「客厅」'
                                : '在「${parents.last}」下新增子位置',
                            hintStyle: TextStyle(fontSize: 13, color: c.textMuted),
                            contentPadding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                        ),
                      ),
                      FindrButton(
                        title: '添加',
                        compact: true,
                        expand: false,
                        onPressed: _add,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Panel(
            title: '位置树',
            hint: '点击设为父级',
            child: all.isEmpty
                ? const EmptyState(
                    title: '还没有位置',
                    hint: '不用手工建。录入时模型认出位置会自动加进来。',
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _renderTree(all, byId, null, 0),
                  ),
          ),
          Panel(
            title: '说明',
            child: Text(
              '不用先建。模型认出位置会自动加进来，也能在这里改层级或名字。',
              style: TextStyle(fontSize: 12, height: 1.6, color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _renderTree(
    List<LocationNode> all,
    Map<String, LocationNode> byId,
    String? pid,
    int depth,
  ) {
    final c = FindrColors.of(context);
    final nodes = _childrenOf(all, pid);
    final out = <Widget>[];
    for (int i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      final isSelected = _parentId == node.id;
      final childCount = _childrenOf(all, node.id).length;

      out.add(
        Padding(
          padding: EdgeInsets.only(left: depth * 16.0),
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 1),
            decoration: BoxDecoration(
              color: isSelected ? c.record.withValues(alpha: 0.08) : Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: ListRow(
              title: node.name,
              subtitle: childCount > 0 ? '$childCount 个子位置' : (isSelected ? '当前父级' : null),
              leading: Icon(
                depth == 0 ? Icons.folder_outlined : Icons.subdirectory_arrow_right_rounded,
                size: depth == 0 ? 20 : 18,
                color: isSelected ? c.record : (depth == 0 ? c.textSecondary : c.textMuted),
              ),
              onTap: () => setState(() => _parentId = isSelected ? null : node.id),
              right: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _ActionPill(
                    label: '改名',
                    icon: Icons.edit_outlined,
                    onTap: () => _showRenameDialog(node),
                  ),
                  const SizedBox(width: Spacing.one),
                  _ActionPill(
                    label: '删除',
                    icon: Icons.delete_outline_rounded,
                    danger: true,
                    onTap: () => _delete(node),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      out.addAll(_renderTree(all, byId, node.id, depth + 1));
    }
    return out;
  }
}

class _ActionPill extends StatelessWidget {
  const _ActionPill({
    required this.label,
    required this.icon,
    required this.onTap,
    this.danger = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final color = danger ? c.danger : c.textSecondary;
    return Material(
      color: danger ? c.danger.withValues(alpha: 0.08) : c.surfaceAlt,
      borderRadius: BorderRadius.circular(Radii.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.pill),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 12.5, color: color),
              const SizedBox(width: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
