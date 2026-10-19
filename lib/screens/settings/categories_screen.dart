/// 分类管理。
///
/// 分类是**用户唯一的组织桶**，也是 P1 自动路由的目标池。
/// 它只决定「这条记忆归到哪一类」；卡片长什么样（有没有位置、有没有步骤）由内容自己决定。
library;

import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/runtime.dart';
import '../../theme/tokens.dart';
import '../../ui/kit.dart';

class CategoriesScreen extends ConsumerStatefulWidget {
  const CategoriesScreen({super.key});

  @override
  ConsumerState<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends ConsumerState<CategoriesScreen> {
  final _name = TextEditingController();
  final _desc = TextEditingController();

  /// 非空 = 正在编辑已有分类。
  String? _editingId;

  RuntimeState get _rt {
    final v = ref.read(runtimeProvider).value;
    if (v == null) throw StateError('运行时还没就绪');
    return v;
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  List<Category> get _categories => listCategories(_rt.driver);

  void _resetForm() {
    _name.clear();
    _desc.clear();
    _editingId = null;
    setState(() {});
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

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _toast('分类要有名字');
      return;
    }
    final list = _categories;
    final editing = _editingId;
    final existing = editing == null ? null : list.firstWhere((c) => c.id == editing);
    try {
      upsertCategory(
        _rt.driver,
        Category(
          id: editing ?? makeId(),
          name: name,
          emoji: null,
          description: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
          // 新分类排在最后；编辑时保持原位置
          sort: existing?.sort ?? list.length,
          isPreset: existing?.isPreset ?? false,
        ),
      );
      _resetForm();
      ref.read(runtimeProvider.notifier).refresh();
      _toast(editing == null ? '已添加' : '已保存');
    } catch (e) {
      // 分类名有唯一索引 —— P1 的路由按名字匹配，重名会让路由结果不确定
      _toast('分类名不能重复（AI 按名字归类）。');
    }
  }

  Future<void> _delete(Category c) async {
    final c2 = FindrColors.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c2.surface,
        title: Text('删除「${c.name}」？', style: TextStyle(fontSize: 16, color: c2.text)),
        content: Text(
          '卡片会变成「无分类」，不会丢。',
          style: TextStyle(fontSize: 13, height: 1.5, color: c2.textSecondary),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: c2.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('删除', style: TextStyle(color: c2.danger)),
          ),
        ],
      ),
    );
    if (yes != true) return;
    final affected = deleteCategory(_rt.driver, c.id, DateTime.now());
    if (_editingId == c.id) _resetForm();
    ref.read(runtimeProvider.notifier).refresh();
    setState(() {});
    _toast(affected > 0 ? '已删除，$affected 张卡片改为无分类' : '已删除');
  }

  void _move(int index, int delta) {
    final list = _categories;
    final j = index + delta;
    if (j < 0 || j >= list.length) return;
    final ids = list.map((c) => c.id).toList();
    final tmp = ids[index];
    ids[index] = ids[j];
    ids[j] = tmp;
    reorderCategories(_rt.driver, ids);
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
    final categories = listCategories(rt.driver);
    final editing = _editingId != null;

    return Scaffold(
      appBar: FindrTopBar(title: '分类'),
      body: ScreenBody.column(
        padding: const EdgeInsets.fromLTRB(
          Spacing.four,
          Spacing.four,
          Spacing.four,
          Spacing.six,
        ),
        children: <Widget>[
          Panel(
            title: '分类池',
            hint: 'AI 拿不准时归到这里',
            child: categories.isEmpty
                ? const EmptyState(title: '还没有分类', hint: '预设分类已删光，在下面新建一个。')
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (int i = 0; i < categories.length; i++) ...<Widget>[
                        if (i > 0) const FindrDivider(),
                        ListRow(
                          title: categories[i].name,
                          subtitle:
                              '${categories[i].description ?? '没有识别描述'}'
                              '${categories[i].isPreset ? ' · 预设' : ''}',
                          onTap: () {
                            final cat = categories[i];
                            _editingId = cat.id;
                            _name.text = cat.name;
                            _desc.text = cat.description ?? '';
                            setState(() {});
                          },
                          right: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              _MiniAction(label: '↑', onTap: () => _move(i, -1)),
                              _MiniAction(label: '↓', onTap: () => _move(i, 1)),
                              _MiniAction(
                                label: '删除',
                                danger: true,
                                onTap: () => _delete(categories[i]),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
          Panel(
            title: editing ? '编辑分类' : '新增分类',
            hint: editing ? '正在编辑已有分类' : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                FindrField(
                  label: '名称',
                  controller: _name,
                  placeholder: '例如：装修记录',
                ),
                const SizedBox(height: Spacing.four),
                FindrField(
                  label: '识别描述（给模型看）',
                  controller: _desc,
                  multiline: true,
                  placeholder: '例如：装修期间临时堆放的物料',
                ),
                const SizedBox(height: Spacing.three),
                Text(
                  '分类只决定归到哪一类。卡片长什么样（有没有位置和步骤）'
                  '由内容自己决定，不用在这里配。',
                  style: TextStyle(fontSize: 11.5, height: 1.45, color: c.textMuted),
                ),
                const SizedBox(height: Spacing.four),
                FindrButton(title: editing ? '保存修改' : '添加分类', onPressed: _save),
                if (editing) ...<Widget>[
                  const SizedBox(height: Spacing.two),
                  FindrButton(
                    title: '取消编辑',
                    variant: FindrButtonVariant.ghost,
                    onPressed: _resetForm,
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

class _MiniAction extends StatelessWidget {
  const _MiniAction({required this.label, required this.onTap, this.danger = false});

  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.two, vertical: Spacing.one),
        child: Text(
          label,
          style: TextStyle(
            fontSize: danger ? 12.5 : 15,
            color: danger ? c.danger : c.textMuted,
          ),
        ),
      ),
    );
  }
}
