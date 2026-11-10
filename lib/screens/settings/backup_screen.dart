/// 备份与恢复。
///
/// **两条硬约束，改这里之前先看一遍**：
///
/// 1. **增量导入**不删除本地数据，同 id 按 `updated_at` 新者胜；
///    **全量导入**会先清空本机全部用户数据与媒体，再完整使用备份；
/// 2. settings 走白名单（core 侧），Key **不走** settings。
///
/// **备份是全量的**：卡片、分类、位置、媒体与 API Key 一起带走，不提供开关；
/// core 只搬运 Key、不读取，导入时用备份里的 Key 覆盖本机同名 Key。
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/backup.dart';
import '../../platform/runtime.dart';
import '../../platform/secure.dart';
import '../../theme/tokens.dart';
import '../../ui/kit.dart';

class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  bool _busy = false;
  ExportPhase? _phase;
  int _elapsed = 0;
  Timer? _ticker;
  ExportOutcome? _exported;
  ImportResult? _imported;

  /// 上一次导入的 Key 同步结果。null = 还没导入过 / 老包没带 Key。
  ({int restored, int cleared})? _keyRestore;

  /// 导入模式：默认增量；全量会先清空本机。
  bool _fullImport = false;

  /// 上一次实际执行的模式（用于结果摘要，避免用户事后切模式把标签改掉）。
  bool _lastFullImport = false;

  /// 挑中的备份文件。**留着 `PlatformFile` 而不是只留路径** ——
  /// 从微信/云盘转存过来的文件是 `content://` 虚拟文档，真正可读的是它自己的
  /// `xFile`，我们手上那条路径未必读得出来（见 `platform/backup.dart` 的说明）。
  PlatformFile? _picked;
  String? _note;

  RuntimeState get _rt {
    final v = ref.read(runtimeProvider).value;
    if (v == null) throw StateError('运行时还没就绪');
    return v;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// 媒体多的库打包要几秒且中间没有进度回调，给个秒表让人知道还活着。
  void _startTicker() {
    _ticker?.cancel();
    _elapsed = 0;
    final started = DateTime.now();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsed = DateTime.now().difference(started).inSeconds);
    });
  }

  /// 读出本机的全部 Key，随包带走。本机没配就返回空 map。
  Future<Map<String, String>> _collectSecrets() async {
    final store = ref.read(apiKeyStoreProvider);
    final out = <String, String>{};
    for (final slot in ApiKeySlot.values) {
      final v = await store.read(slot);
      if (v != null && v.isNotEmpty) out[slot.storageKey] = v;
    }
    return out;
  }

  Future<void> _runExport() async {
    setState(() {
      _busy = true;
      _note = null;
      _exported = null;
    });
    _startTicker();
    try {
      final out = await exportToFile(
        _rt.driver,
        version: _rt.version,
        onPhase: (p) => setState(() => _phase = p),
        secrets: await _collectSecrets(),
      );
      if (!mounted) return;
      setState(() => _exported = out);
      await shareBackup(out.path, out.fileName);
    } catch (e) {
      if (mounted) _dialog('导出失败', '$e');
    } finally {
      _ticker?.cancel();
      if (mounted) {
        setState(() {
          _busy = false;
          _phase = null;
        });
      }
    }
  }

  Future<void> _pick() async {
    setState(() {
      _note = null;
      _imported = null;
      _keyRestore = null;
    });
    try {
      final file = await pickBackupFile();
      if (file == null || !mounted) return;
      setState(() => _picked = file);
    } catch (e) {
      if (mounted) _dialog('打开文件选择器失败', '$e');
    }
  }

  Future<void> _import() async {
    final picked = _picked;
    if (picked == null) return;
    if (_fullImport && !await _confirmFullImport()) return;
    setState(() {
      _busy = true;
      _note = null;
      _keyRestore = null;
      _lastFullImport = _fullImport;
    });
    try {
      final res = await importFromPlatformFile(
        _rt.driver,
        picked,
        fullReplace: _lastFullImport,
      );
      final keys = await _restoreKeys(res.apiKeys, fullReplace: _lastFullImport);
      if (!mounted) return;
      setState(() {
        _picked = null;
        _imported = res;
        _keyRestore = keys;
      });
      // 导入直接改了 DB 与安全存储，必须让运行时重读一遍，否则界面还是旧的
      await ref.read(runtimeProvider.notifier).refresh();
      if (!mounted) return;
      _toast(_lastFullImport ? '全量导入完成，本机数据已按备份替换' : '增量导入完成，本地数据已更新');
    } catch (e) {
      if (mounted) {
        _dialog('导入失败', '$e\n\n常见原因：不是 Findr 备份，或传输中损坏。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 全量导入是不可撤销的破坏性操作，必须二次确认。
  Future<bool> _confirmFullImport() async {
    final c = FindrColors.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: Text('全量导入会清空本机数据', style: TextStyle(fontSize: 16, color: c.text)),
        content: Text(
          '本机现有的卡片、分类、位置、设置、媒体与 API Key 都会被清空，'
          '然后完整使用这份备份。此操作不可撤销。',
          style: TextStyle(fontSize: 13, height: 1.5, color: c.textSecondary),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: c.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('清空并导入', style: TextStyle(color: c.danger)),
          ),
        ],
      ),
    );
    return yes == true;
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

  /// 把本机 Key 同步成备份里的状态：有的覆盖，没有的清空。
  ///
  /// [incoming] 为 null 表示老包没有 `apiKeys` 字段：增量导入不动本机 Key；
  /// 全量导入按“备份没有”处理，清空本机 Key。
  Future<({int restored, int cleared})?> _restoreKeys(
    Map<String, String>? incoming, {
    required bool fullReplace,
  }) async {
    final source = incoming ?? (fullReplace ? const <String, String>{} : null);
    if (source == null) return null;

    // “备份里有哪几把就覆盖哪几把、没有就清空”这条规则在 platform/secure.dart 里有单测押着。
    final plan = keysToRestore(source);
    final store = ref.read(apiKeyStoreProvider);
    var restored = 0;
    var cleared = 0;
    for (final entry in plan.entries) {
      final before = await store.read(entry.key);
      if (entry.value == null) {
        if (before != null && before.isNotEmpty) cleared++;
        await store.write(entry.key, null);
      } else {
        await store.write(entry.key, entry.value);
        restored++;
      }
    }
    return (restored: restored, cleared: cleared);
  }

  void _dialog(String title, String body) {
    final c = FindrColors.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: Text(title, style: TextStyle(fontSize: 16, color: c.text)),
        content: Text(body, style: TextStyle(fontSize: 13, height: 1.5, color: c.textSecondary)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('好', style: TextStyle(color: c.record)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final rt = ref.watch(runtimeProvider).value;
    if (rt == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final exported = _exported;
    final imported = _imported;

    return Scaffold(
      appBar: FindrTopBar(title: '备份与恢复'),
      body: ScreenBody.column(
        padding: const EdgeInsets.fromLTRB(
          Spacing.four,
          Spacing.four,
          Spacing.four,
          Spacing.six,
        ),
        children: <Widget>[
          Text(
            '备份文件用于换机或重装后恢复数据。',
            style: TextStyle(fontSize: 13, height: 1.5, color: c.textSecondary),
          ),

          // ── 导出 ─────────────────────────────────────────
          Panel(
            title: '导出',
            hint: '包含卡片、分类、位置、媒体素材与模型 API 密钥',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                FindrButton(
                  title: _busy && _phase != null ? _phaseText(_phase!, _elapsed) : '导出并分享',
                  loading: _busy,
                  onPressed: _runExport,
                ),
                if (exported != null) ...<Widget>[
                  const SizedBox(height: Spacing.three),
                  Notice(
                    title: '已生成 ${exported.fileName}',
                    tone: NoticeTone.success,
                    text:
                        '卡片 ${exported.report.cards} · 分类 ${exported.report.categories} · '
                        '位置 ${exported.report.locations} · 别名 ${exported.report.aliases}\n'
                        '媒体 ${exported.report.mediaWritten}/${exported.report.mediaTotal} 个 · '
                        '${_fmtBytes(exported.report.bytes)}'
                        '${exported.report.mediaMissing.isEmpty ? '' : '\n⚠ 有 ${exported.report.mediaMissing.length} 个媒体文件在磁盘上已不存在，没能进包（DB 里仍引用着它们）'}',
                  ),
                  const SizedBox(height: Spacing.two),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FindrButton(
                      title: '再分享一次',
                      variant: FindrButtonVariant.secondary,
                      compact: true,
                      expand: false,
                      onPressed: () => shareBackup(exported.path, exported.fileName),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // ── 导入 ─────────────────────────────────────────
          Panel(
            title: '导入',
            hint: _fullImport ? '先清空本机，再完整恢复' : '保留本机，只合并备份',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '增量导入：同 id 卡片按修改时间新者胜；分类/位置重名保留本机、新名字插入；'
                  '媒体按路径覆盖；设置与 API Key 全量覆盖。\n'
                  '全量导入：先清空本机全部数据，再完整使用备份。',
                  style: TextStyle(fontSize: 11.5, height: 1.45, color: c.textMuted),
                ),
                const SizedBox(height: Spacing.three),
                Row(
                  children: <Widget>[
                    FindrChip(
                      label: '增量导入',
                      dense: true,
                      active: !_fullImport,
                      onPressed: () => setState(() => _fullImport = false),
                    ),
                    const SizedBox(width: Spacing.two),
                    FindrChip(
                      label: '全量导入',
                      dense: true,
                      active: _fullImport,
                      onPressed: () => setState(() => _fullImport = true),
                    ),
                  ],
                ),
                if (_fullImport) ...<Widget>[
                  const SizedBox(height: Spacing.two),
                  Text(
                    '全量导入会清空本机卡片、分类、位置、设置、媒体与 API Key，再完整恢复备份。',
                    style: TextStyle(fontSize: 11.5, height: 1.45, color: c.danger),
                  ),
                ],
                const SizedBox(height: Spacing.four),
                FindrButton(
                  title: '选择备份文件',
                  variant: FindrButtonVariant.secondary,
                  onPressed: _pick,
                ),
                if (_picked != null) ...<Widget>[
                  const SizedBox(height: Spacing.three),
                  ListRow(title: _picked!.name, subtitle: '已选中，点下面开始导入'),
                  const SizedBox(height: Spacing.two),
                  FindrButton(
                    title: '开始导入',
                    variant: FindrButtonVariant.primary,
                    loading: _busy,
                    onPressed: _import,
                  ),
                  const SizedBox(height: Spacing.two),
                  FindrButton(
                    title: '换一个文件',
                    variant: FindrButtonVariant.ghost,
                    onPressed: () => setState(() {
                      _picked = null;
                      _imported = null;
                    }),
                  ),
                ],
                if (imported != null) ...<Widget>[
                  const SizedBox(height: Spacing.three),
                  Notice(
                    title: '导入完成 · 备份来自 ${_fmtWhen(imported.manifestInfo.exportedAt)}',
                    tone: NoticeTone.success,
                    text: _importSummary(imported),
                  ),
                ],
                if (_keyRestore != null &&
                    (_keyRestore!.restored > 0 || _keyRestore!.cleared > 0)) ...<Widget>[
                  const SizedBox(height: Spacing.two),
                  Notice(
                    title: 'API Key',
                    tone: NoticeTone.info,
                    text: _keyRestore!.restored > 0
                        ? '已恢复 ${_keyRestore!.restored} 把 Key'
                            '${_keyRestore!.cleared > 0 ? '，并清空 ${_keyRestore!.cleared} 把备份里没有的 Key' : ''}。'
                        : '已清空 ${_keyRestore!.cleared} 把备份里没有的 Key。',
                  ),
                ],
              ],
            ),
          ),

          if (_note != null) Notice(text: _note!),


        ],
      ),
    );
  }

  String _importSummary(ImportResult r) {
    final rep = r.report;
    final lines = <String>[
      '模式 ${_lastFullImport ? '全量覆盖' : '增量合并'}',
      '卡片 新增 ${rep.cardsInserted} · 更新 ${rep.cardsUpdated} · 保留 ${rep.cardsKeptLocal}',
      '媒体 写入 ${rep.mediaWritten} · 覆盖 ${rep.mediaOverwritten}',
      '分类 新增 ${rep.categoriesInserted} · 保留 ${rep.categoriesKeptLocal}',
      '位置 新增 ${rep.locationsInserted} · 保留 ${rep.locationsKeptLocal}',
      '别名 新增 ${rep.aliasesInserted} · 设置 写入 ${rep.settingsWritten}（全量覆盖）',
    ];
    if (rep.remappedCategoryRefs + rep.remappedLocationRefs > 0) {
      lines.add('按名字重对齐：分类 ${rep.remappedCategoryRefs} · 位置 ${rep.remappedLocationRefs}');
    }
    if (rep.droppedRefs > 0) {
      lines.add('⚠ ${rep.droppedRefs} 处引用对不上，已置空');
    }
    if (rep.conflicts.isNotEmpty) {
      final names = rep.conflicts
          .take(6)
          .map((c) => '· ${c.kind == 'category' ? '分类' : '位置'}「${c.name}」')
          .join('\n');
      lines.add('同名冲突 ${rep.conflicts.length} 处（保留了本机那份）：\n$names');
    }
    return lines.join('\n');
  }

  String _phaseText(ExportPhase phase, int elapsed) {
    final secs = elapsed > 0 ? '（${elapsed}s）' : '';
    return phase == ExportPhase.packing ? '正在打包…$secs' : '正在写入文件…$secs';
  }

  String _fmtBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  String _fmtWhen(String iso) {
    if (iso.isEmpty) return '未知时间';
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    final l = d.toLocal();
    String p(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${p(l.month)}-${p(l.day)} ${p(l.hour)}:${p(l.minute)}';
  }
}
