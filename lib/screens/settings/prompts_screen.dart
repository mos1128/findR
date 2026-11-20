/// 提示词自定义。
///
/// 只放开四段正文；输出 schema 与调用示例随版本固定 ——
/// schema 的字段名与解析器一一对应，放开它等于把「解析失败」交给用户亲手制造，
/// 而报错里不会出现「你改了 schema」这几个字。
library;

import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/runtime.dart';
import '../../theme/tokens.dart';
import '../../ui/kit.dart';
import '../../ui/runtime_fallback.dart';

/// 设置页那一行要显示的状态：「2 条已修改 · 1 条默认已更新」。
String promptOverridesSummary(SqliteDriver db) {
  final all = readPromptOverrides(db);
  if (all.isEmpty) return '全部为默认';
  final stale = all.entries
      .where((e) => e.value.preset != promptPresetHash(e.key))
      .length;
  return stale == 0 ? '${all.length} 条已修改' : '${all.length} 条已修改 · $stale 条默认已更新';
}

enum _PromptState {
  defaults,

  /// 用户改过，且改的是当前这一版默认。
  edited,

  /// 用户改过，但之后我们发版把默认改了。
  stale,
}

_PromptState _stateOf(PromptId id, PromptOverride? override) {
  if (override == null) return _PromptState.defaults;
  return override.preset == promptPresetHash(id)
      ? _PromptState.edited
      : _PromptState.stale;
}

class PromptsScreen extends ConsumerStatefulWidget {
  const PromptsScreen({super.key});

  @override
  ConsumerState<PromptsScreen> createState() => _PromptsScreenState();
}

class _PromptsScreenState extends ConsumerState<PromptsScreen> {
  Future<void> _open(PromptId id) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => _PromptEditorScreen(id: id)),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final runtimeState = ref.watch(runtimeProvider);
    final rt = runtimeState.value;
    if (rt == null) return RuntimeFallback(title: '提示词', state: runtimeState);
    final overrides = readPromptOverrides(rt.driver);

    return Scaffold(
      appBar: FindrTopBar(title: '提示词'),
      body: ScreenBody.column(
        padding: const EdgeInsets.fromLTRB(
          Spacing.four,
          Spacing.four,
          Spacing.four,
          Spacing.six,
        ),
        children: <Widget>[
          Panel(
            title: '当前设置',
            hint: promptOverridesSummary(rt.driver),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (int i = 0; i < PromptId.values.length; i++) ...<Widget>[
                  if (i > 0) const FindrDivider(),
                  _row(c, PromptId.values[i], overrides[PromptId.values[i]]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(FindrColors c, PromptId id, PromptOverride? override) {
    final (String label, Color color) = switch (_stateOf(id, override)) {
      _PromptState.defaults => ('默认', c.textMuted),
      _PromptState.edited => ('已修改', c.record),
      _PromptState.stale => ('默认已更新', c.badgeConfirm),
    };
    return ListRow(
      title: id.title,
      subtitle: id.use,
      onTap: () => _open(id),
      right: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(label, style: TextStyle(fontSize: 12, color: color)),
          const SizedBox(width: Spacing.two),
          Icon(Icons.chevron_right_rounded, size: 20, color: c.textMuted),
        ],
      ),
    );
  }
}

class _PromptEditorScreen extends ConsumerStatefulWidget {
  const _PromptEditorScreen({required this.id});

  final PromptId id;

  @override
  ConsumerState<_PromptEditorScreen> createState() => _PromptEditorScreenState();
}

class _PromptEditorScreenState extends ConsumerState<_PromptEditorScreen> {
  final _ctrl = TextEditingController();
  bool _inited = false;

  RuntimeState get _rt {
    final v = ref.read(runtimeProvider).value;
    if (v == null) throw StateError('运行时尚未就绪');
    return v;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _toast(String message) => showFindrToast(context, message);

  void _save() {
    final error = validatePromptBody(widget.id, _ctrl.text);
    if (error != null) {
      _toast(error);
      return;
    }
    writePromptBody(_rt.driver, widget.id, _ctrl.text);
    setState(() {});
    _toast('已保存');
  }

  /// 丢掉用户的改法、换回内置正文。两条路都走这里：恢复默认、改用新版默认。
  Future<void> _restore({
    required String title,
    required String body,
    required String confirm,
  }) async {
    final c = FindrColors.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: Text(title, style: TextStyle(fontSize: 16, color: c.text)),
        content: Text(
          body,
          style: TextStyle(fontSize: 13, height: 1.5, color: c.textSecondary),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: c.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirm, style: TextStyle(color: c.danger)),
          ),
        ],
      ),
    );
    if (yes != true) return;
    resetPromptBody(_rt.driver, widget.id);
    _ctrl.text = promptDefaultBody(widget.id);
    setState(() {});
    _toast('已恢复默认');
  }

  /// 「保留我的」：确认自己写的那份不用升级 —— 把哈希盖成当前版本，不再提示。
  void _keepMine(PromptOverride custom) {
    writePromptBody(_rt.driver, widget.id, custom.text);
    setState(() {});
    _toast('已保留你的修改');
  }

  @override
  Widget build(BuildContext context) {
    final runtimeState = ref.watch(runtimeProvider);
    final rt = runtimeState.value;
    if (rt == null) {
      return RuntimeFallback(title: widget.id.title, state: runtimeState);
    }

    final custom = readPromptOverrides(rt.driver)[widget.id];
    if (!_inited) {
      _ctrl.text = custom?.text ?? promptDefaultBody(widget.id);
      _inited = true;
    }
    final stale = _stateOf(widget.id, custom) == _PromptState.stale;

    final vars = promptVars(widget.id);
    final note = vars.isEmpty
        ? '输出格式与示例由程序固定，不在此编辑。'
        : '可用变量：${vars.map((v) => '{{$v}}').join('、')}，发送前会替换成当前内容。\n'
              '输出格式与示例由程序固定，不在此编辑。';

    return Scaffold(
      appBar: FindrTopBar(title: widget.id.title),
      body: ScreenBody.column(
        padding: const EdgeInsets.fromLTRB(
          Spacing.four,
          Spacing.three,
          Spacing.four,
          Spacing.six,
        ),
        children: <Widget>[
          if (stale)
            Notice(
              tone: NoticeTone.warn,
              text: '新版本的默认提示词有改动，改用新版会丢掉你的修改。',
              action: Wrap(
                spacing: Spacing.two,
                runSpacing: Spacing.one,
                children: <Widget>[
                  FindrButton(
                    title: '改用新版默认',
                    variant: FindrButtonVariant.secondary,
                    compact: true,
                    expand: false,
                    onPressed: () => _restore(
                      title: '改用新版默认？',
                      body: '你改过的这一份会被覆盖，且无法找回。',
                      confirm: '改用新版',
                    ),
                  ),
                  FindrButton(
                    title: '保留我的',
                    variant: FindrButtonVariant.ghost,
                    compact: true,
                    expand: false,
                    onPressed: () => _keepMine(custom!),
                  ),
                ],
              ),
            ),
          FindrField(
            label: '正文',
            controller: _ctrl,
            multiline: true,
            minLines: 10,
            maxLines: 30,
            note: note,
          ),
          Row(
            children: <Widget>[
              Expanded(child: FindrButton(title: '保存', onPressed: _save)),
              if (custom != null) ...<Widget>[
                const SizedBox(width: Spacing.three),
                Expanded(
                  child: FindrButton(
                    title: '恢复默认',
                    variant: FindrButtonVariant.secondary,
                    onPressed: () => _restore(
                      title: '恢复默认？',
                      body: '内置提示词会替换你改过的内容，且无法找回。',
                      confirm: '恢复默认',
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
