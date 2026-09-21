/// 备份与恢复 —— 对应 RN 的 `app/settings/backup.tsx`。
///
/// **两条来自需求与《技术设计》第七节的硬约束，改这里之前先读那两处**：
///
/// 1. 导出文件**永远不含 API Key 与安全存储内容**（core 侧走白名单，不是靠过滤）；
/// 2. 导入**不删除本地任何数据**，同 id 按 `updated_at` 新者胜。
///
/// ⚠️ **这一版没有加密**（2026-09-20 决策）：`.findrpack` 就是一个套了 7 字节头的 ZIP，
/// 谁拿到谁能读到全部内容。界面上必须把这件事说白 —— 页顶红条 + 导出前的二次确认框，
/// **两处都要**，缺一处就会有人以为它是加密的。
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/backup.dart';
import '../../platform/runtime.dart';
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

  /// 明文导出等于把整个记忆库摊开给任何拿到文件的人，而分享面板一点就发出去。
  /// 所以这里挡一道：说清楚它不是加密的，再让用户决定。
  Future<void> _confirmThenExport() async {
    final c = FindrColors.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: Text('这份备份没有加密', style: TextStyle(fontSize: 16, color: c.danger)),
        content: Text(
          '文件里就是你全部卡片的内容与图片、录音，拿到它的人不需要密码就能直接打开。\n\n'
          '请只保存到自己信得过的地方（自己的电脑、私人云盘），别发到群聊里。\n\n'
          '加密会在这个功能的下一个版本补上。',
          style: TextStyle(fontSize: 13, height: 1.6, color: c.textSecondary),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: c.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('继续导出', style: TextStyle(color: c.danger)),
          ),
        ],
      ),
    );
    if (yes == true) await _runExport();
  }

  Future<void> _pick() async {
    setState(() {
      _note = null;
      _imported = null;
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
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      final bytes = await readBackupBytes(picked);
      final res = await importFromBytes(_rt.driver, bytes);
      if (!mounted) return;
      setState(() => _imported = res);
      // 导入直接改了 DB，必须让运行时把设置重新读一遍，否则界面还是旧的
      await ref.read(runtimeProvider.notifier).refresh();
    } catch (e) {
      if (mounted) {
        _dialog('导入失败', '$e\n\n最常见的原因：文件不是 Findr 的备份，或者传输过程中损坏了。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
            '备份用来换手机或重装后把记忆搬回去。它是一个文件（$backupExt），'
            '内容就是你全部卡片与图片、录音。',
            style: TextStyle(fontSize: 13, height: 1.5, color: c.textSecondary),
          ),
          // 红条：**需求与决策要求界面必须明说不加密**，这一条不许删
          Notice(
            title: '当前版本不加密',
            tone: NoticeTone.danger,
            icon: Icons.lock_open_rounded,
            text:
                '这个文件没有任何密码保护 —— 用解压工具就能直接看到里面的全部内容。'
                '请只把它放在自己信得过的地方（自己的电脑、私人云盘），不要发到群聊或公共空间。\n'
                '加密计划在这个功能的下一个版本补上。',
          ),

          // ── 导出 ─────────────────────────────────────────
          Panel(
            title: '导出',
            hint: '含全部卡片、分类、位置、别名与图片音频',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '不含 API Key、不含任何安全存储内容 —— 导进去也还是要在新机器上重新填一次 Key。',
                  style: TextStyle(fontSize: 11.5, height: 1.45, color: c.textMuted),
                ),
                const SizedBox(height: Spacing.four),
                FindrButton(
                  title: _busy && _phase != null ? _phaseText(_phase!, _elapsed) : '导出并分享',
                  loading: _busy,
                  onPressed: _confirmThenExport,
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
            hint: '不会删除本机任何东西',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '同一张卡在两台机器上都改过时，修改时间较新的那份保留；分类与位置按名字对齐，'
                  '对齐不上才新建。媒体按相对路径覆盖。',
                  style: TextStyle(fontSize: 11.5, height: 1.45, color: c.textMuted),
                ),
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
                    variant: FindrButtonVariant.danger,
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
              ],
            ),
          ),

          if (_note != null) Notice(text: _note!),

          Panel(
            title: '几条要记住的',
            child: Text(
              '· 文件是明文的：别把它交给别人，也别放在共享空间里。\n'
              '· 导出的文件在 App 的缓存目录里，递出去之后系统随时可能清掉它 —— 导出完就分享/保存到别处。\n'
              '· 导入是合并，不是覆盖：本机多出来的卡片不会被删。\n'
              '· 重复导入同一个文件是安全的，结果一致（按 id 幂等）。\n'
              '· 文件传坏了能被发现（包里每个文件都带校验和），会明确报「校验和不符」。',
              style: TextStyle(fontSize: 11.5, height: 1.7, color: c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  String _importSummary(ImportResult r) {
    final rep = r.report;
    final lines = <String>[
      '卡片：新增 ${rep.cardsInserted} / 更新 ${rep.cardsUpdated} / 保留本机 ${rep.cardsKeptLocal}',
      '媒体：写入 ${rep.mediaWritten}（覆盖 ${rep.mediaOverwritten}）',
      '分类：新增 ${rep.categoriesInserted} / 保留本机 ${rep.categoriesKeptLocal}',
      '位置：新增 ${rep.locationsInserted} / 保留本机 ${rep.locationsKeptLocal}',
      '别名：新增 ${rep.aliasesInserted} · 设置：写入 ${rep.settingsWritten} / 保留本机 ${rep.settingsKeptLocal}',
    ];
    if (rep.remappedCategoryRefs + rep.remappedLocationRefs > 0) {
      lines.add('按名字重新对齐的引用：分类 ${rep.remappedCategoryRefs} · 位置 ${rep.remappedLocationRefs}');
    }
    if (rep.droppedRefs > 0) {
      lines.add('⚠ 有 ${rep.droppedRefs} 处引用对不上、只能置空');
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
