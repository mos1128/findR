/// 位置树 —— 对应 RN 的 `app/settings/locations.tsx`。
///
/// 位置是**检索质量的命脉**：卡片的位置串（`path_names`）是冗余列，
/// 按位置搜索靠的就是它。所以改名之后必须跟一次 `refreshPathNames`，
/// 否则**按旧名字搜不到、按新名字也搜不到**（M3 的验收项）。
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

  /// 非空 = 正在重命名这一条。
  String? _renameId;

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

  void _rename(String id) {
    final name = _renameText.text.trim();
    if (name.isEmpty) return;
    renameLocation(_rt.driver, id, name);
    // ⚠️ 改名后同步卡片的冗余位置串，否则按旧名/新名都搜不到
    final changed = refreshPathNames(_rt.driver, DateTime.now());
    _renameId = null;
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
          '有子节点、或被卡片引用的位置不能删 —— 静默删掉会让卡片的路径指向空洞。',
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
            ? '删不掉：它下面还有 ${res.count} 个子位置，先把子位置处理掉。'
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
            title: '当前层级',
            hint: '点一个位置即为「往它下面加」',
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
                      label: '🏠 根',
                      active: _parentId == null,
                      onPressed: () => setState(() => _parentId = null),
                    ),
                    for (final name in parents) ...<Widget>[
                      Text('›', style: TextStyle(color: c.textMuted)),
                      Text(name, style: TextStyle(fontSize: 13, color: c.text)),
                    ],
                  ],
                ),
                const SizedBox(height: Spacing.three),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: FindrField(
                        label: '在这里加一个位置',
                        controller: _newName,
                        placeholder: _parentId == null ? '例如：客厅' : '例如：电视柜',
                      ),
                    ),
                    const SizedBox(width: Spacing.two),
                    Padding(
                      padding: const EdgeInsets.only(top: 22),
                      child: FindrButton(
                        title: '添加',
                        expand: false,
                        onPressed: _add,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Panel(
            title: '位置树',
            hint: '长按改名',
            child: all.isEmpty
                ? const EmptyState(
                    title: '还没有位置',
                    hint: '位置不一定要手工建 —— 录入时模型提到存放位置就会自动长出来。',
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _renderTree(all, byId, null, 0),
                  ),
          ),
          Panel(
            title: '说明',
            child: Text(
              '· 位置树由解析结果**增量长出来**：模型在内容里提到「电视柜下面的抽屉」'
              '就会自动建好这一串，不必先来这里手工建。\n'
              '· 改名会同步更新所有卡片的位置串（否则按新旧名字都搜不到）。\n'
              '· 同一个父节点下不能有同名位置。',
              style: TextStyle(fontSize: 11.5, height: 1.6, color: c.textMuted),
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
    for (final node in nodes) {
      if (_renameId == node.id) {
        out.add(
          Padding(
            padding: EdgeInsets.fromLTRB(depth * 16, Spacing.two, 0, Spacing.two),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  child: FindrField(label: '新名称', controller: _renameText),
                ),
                const SizedBox(width: Spacing.two),
                Padding(
                  padding: const EdgeInsets.only(bottom: 1),
                  child: FindrButton(
                    title: '保存',
                    compact: true,
                    expand: false,
                    onPressed: () => _rename(node.id),
                  ),
                ),
                const SizedBox(width: Spacing.one),
                Padding(
                  padding: const EdgeInsets.only(bottom: 1),
                  child: FindrButton(
                    title: '取消',
                    compact: true,
                    expand: false,
                    variant: FindrButtonVariant.ghost,
                    onPressed: () => setState(() => _renameId = null),
                  ),
                ),
              ],
            ),
          ),
        );
      } else {
        out.add(
          Padding(
            padding: EdgeInsets.only(left: depth * 16.0),
            child: ListRow(
              title: node.name,
              subtitle: '${_childrenOf(all, node.id).length} 个子位置',
              onTap: () => setState(() => _parentId = node.id),
              onLongPress: () => setState(() {
                _renameId = node.id;
                _renameText.text = node.name;
              }),
              right: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  InkWell(
                    onTap: () => setState(() {
                      _renameId = node.id;
                      _renameText.text = node.name;
                    }),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Spacing.two),
                      child: Text('改名', style: TextStyle(fontSize: 12.5, color: c.textMuted)),
                    ),
                  ),
                  InkWell(
                    onTap: () => _delete(node),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Spacing.two),
                      child: Text('删除', style: TextStyle(fontSize: 12.5, color: c.danger)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      out.addAll(_renderTree(all, byId, node.id, depth + 1));
    }
    return out;
  }
}
