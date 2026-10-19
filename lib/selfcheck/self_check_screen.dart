/// 自检屏 —— 真机上跑的两组检查，**命门（FTS5 + trigram）的第二层载体**。
/// 依据：两层自检的分工 —— 本地纯 Dart 验 SQL 写法，真机验打进包的那份 SQLite。
///
/// 两组的分工（**别把两组合并成一组**）：
///
/// | 组 | 验什么 | 跑在哪 |
/// |---|---|---|
/// | 核心 | FTS5 编译选项 / trigram / 3 字中文 `MATCH` / 迁移建表（`runCoreSelfCheck`）| **优先跑在真实库文件上**；拿不到沙盒目录（`flutter test`）就退回内存库 |
/// | 设备 | PRAGMA / 外键 / 嵌套事务 / 媒体文件往返 / 整库打包往返 | 只有真机能跑；跑不了时显式说明「不算失败」，不留红项 |
///
/// ⚠️ **判断标准**：两组都全绿 ⇒ 命门与设备层都过。
/// 只要「FTS5 编译选项」或「3 字中文 MATCH」有一个 ❌，**整套检索方案就得重新评估**
/// （那两条正是我们押的全部赌注）。
///
/// 这一屏是**临时入口**：真正的界面还没做（见交接 §1「UI 直接在 Flutter 里重构」）。
library;

import 'dart:async';

import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';

import '../platform/app_paths.dart';
import '../platform/db.dart';
import '../platform/device_selfcheck.dart';

final class SelfCheckScreen extends StatefulWidget {
  const SelfCheckScreen({super.key});

  @override
  State<SelfCheckScreen> createState() => _SelfCheckScreenState();
}

class _SelfCheckScreenState extends State<SelfCheckScreen> {
  SelfCheckReport? _coreReport;
  String _coreTarget = '内存库';
  DeviceSelfCheckOutcome? _device;
  Object? _error;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    if (mounted) setState(() => _error = null);

    Sqlite3Driver? db;
    SelfCheckReport? core;
    DeviceSelfCheckOutcome? device;
    Object? error;
    var target = '内存库';
    try {
      // 能拿到沙盒目录就**在真实库文件上跑** —— 那才是真机上真正会被用的那个库，
      // 与内存库在 SQLite 里走的是不同代码路径（WAL / 文件锁）。
      if (AppPaths.ready) {
        try {
          db = openFindrDb();
          target = '真实库文件';
        } catch (e) {
          db = null;
          device = DeviceSelfCheckUnavailable('打开库文件失败，已退回内存库：$e');
        }
      }
      device ??= await runDeviceSelfCheck(db: db);
      core = runCoreSelfCheck(db);
    } catch (e) {
      error = e;
    } finally {
      // 自检不该长期占着库文件。真实界面起来之后这里改成复用常驻连接。
      db?.close();
    }

    if (!mounted) {
      _running = false;
      return;
    }
    setState(() {
      _coreReport = core;
      _coreTarget = target;
      _device = device;
      _error = error;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final core = _coreReport;
    final device = _device;

    return Scaffold(
      appBar: AppBar(
        title: const Text('系统运行诊断'),
        actions: <Widget>[
          IconButton(
            tooltip: '重新诊断',
            onPressed: _running ? null : _run,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            const Text(
              '检测底层数据库模块完整性、全文索引检索能力与真机沙盒读写状态。\n'
              '所有检测项通过表示设备运行环境良好。',
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
            if (core != null) ...<Widget>[
              _SectionTitle('核心 · FTS5 + trigram（跑在$_coreTarget上）'),
              _VerdictBanner(ok: core.passed, text: core.verdict),
              for (final item in core.items) _ItemTile(item: item),
            ],
            if (device != null) ...<Widget>[
              const SizedBox(height: 20),
              const _SectionTitle('设备层 · 只有真机才成立的几件事'),
              switch (device) {
                DeviceSelfCheckDone(:final items, :final verdict, :final passed) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _VerdictBanner(ok: passed, text: verdict),
                    for (final item in items) _ItemTile(item: item),
                  ],
                ),
                DeviceSelfCheckUnavailable(:final reason) => Card(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('未运行（不算失败）：\n$reason'),
                  ),
                ),
              },
            ],
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}

class _VerdictBanner extends StatelessWidget {
  const _VerdictBanner({required this.ok, required this.text});

  final bool ok;
  final String text;

  @override
  Widget build(BuildContext context) {
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
              child: Text(text, style: Theme.of(context).textTheme.titleMedium),
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
      // 可选中：真机上要能把实际观测值复制出来发我
      subtitle: SelectableText(item.detail),
    );
  }
}
