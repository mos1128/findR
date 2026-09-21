/// 命门自检屏（**第 2 层：Flutter / 真机**）—— `Flutter迁移交接.md` §6.1。
///
/// 它跑的是 `findr_core` 里那份**同一份** `runCoreSelfCheck()`，但执行环境完全不同：
/// 这里的 SQLite 是 `package:sqlite3` 的 **Dart build hooks 编出来、随 APK 一起发布的那一份**。
/// 第 1 层（`dart test`）跑在 Dart VM 上，验不了这件事。
///
/// ⚠️ **判断标准**：屏幕上所有项都 ✅ ⇒ 第 2 层通过。
/// 只要「FTS5 编译选项」或「3 字中文 MATCH」有一个 ❌，**整套检索方案就得重新评估**
/// （那两条正是我们押的全部赌注）。
///
/// 这一屏是**临时的入口**：真正的界面还没做（见交接 §1「UI 直接在 Flutter 里重构」）。
library;

import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';

final class SelfCheckScreen extends StatefulWidget {
  const SelfCheckScreen({super.key});

  @override
  State<SelfCheckScreen> createState() => _SelfCheckScreenState();
}

class _SelfCheckScreenState extends State<SelfCheckScreen> {
  SelfCheckReport? _report;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  void _run() {
    try {
      // 内存库：自检不该依赖文件系统权限 —— 那会引入与被测问题无关的失败源。
      // 「文件路径 + 文件 IO」的验证属于第一版真实界面那一步（届时接 path_provider）。
      setState(() {
        _report = runCoreSelfCheck();
        _error = null;
      });
    } catch (e) {
      setState(() {
        _report = null;
        _error = e;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('自检 · 命门第 2 层'),
        actions: <Widget>[
          IconButton(
            tooltip: '重跑',
            onPressed: _run,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            const Text(
              '这一屏验的是「打进 APK 的那份 SQLite 带不带 FTS5 + trigram」。\n'
              '全部 ✅ 才算第 2 层通过；本地 dart test 通过不等于这里通过。',
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('自检本身抛异常（这本身就是失败）：\n$_error'),
                ),
              ),
            if (report != null) ...<Widget>[
              _VerdictBanner(report: report),
              const SizedBox(height: 12),
              for (final item in report.items) _ItemTile(item: item),
            ],
          ],
        ),
      ),
    );
  }
}

class _VerdictBanner extends StatelessWidget {
  const _VerdictBanner({required this.report});

  final SelfCheckReport report;

  @override
  Widget build(BuildContext context) {
    final ok = report.passed;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: ok ? const Color(0xFFE6F4EA) : scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: <Widget>[
            Icon(
              ok ? Icons.verified : Icons.dangerous,
              color: ok ? const Color(0xFF1E8E3E) : scheme.error,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                report.verdict,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item});

  final SelfCheckItem item;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(
        item.ok ? Icons.check_circle : Icons.cancel,
        color: item.ok ? const Color(0xFF1E8E3E) : Theme.of(context).colorScheme.error,
      ),
      title: Text(item.name),
      subtitle: SelectableText(item.detail),
    );
  }
}
