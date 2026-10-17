/// 设置主页。
///
/// 正式商用发版标准架构：
/// - 模型服务：LLM 与 ASR 状态
/// - 智能偏好：多模态分析、搜索智能解答
/// - 空间与分类：位置树与分类管理
/// - 数据与维护：备份恢复与后台队列诊断
/// - 关于：规范版本与关于信息，高级技术参数收拢于调试弹窗
library;

import 'dart:async';

import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../platform/runtime.dart';
import '../../platform/update.dart';
import '../../selfcheck/self_check_screen.dart';
import '../../theme/tokens.dart';
import '../../ui/kit.dart';
import 'backup_screen.dart';
import 'categories_screen.dart';
import 'locations_screen.dart';
import 'provider_settings_screen.dart';
import 'update_flow.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _busy = false;

  RuntimeState get _rt {
    final v = ref.read(runtimeProvider).value;
    if (v == null) throw StateError('运行时还没就绪');
    return v;
  }

  Future<void> _run(Future<String?> Function(RuntimeState rt) body, {String? title}) async {
    setState(() => _busy = true);
    try {
      final msg = await body(_rt);
      if (mounted && msg != null) _dialog(title ?? '完成', msg);
    } catch (e) {
      if (mounted) _dialog(title == null ? '失败' : '$title失败', '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 本页统一的弹窗外壳（底色与标题样式只在这一处，别在各弹窗里各写一份）。
  AlertDialog _alert(
    BuildContext ctx, {
    required String title,
    required Widget content,
    required List<Widget> actions,
  }) {
    final c = FindrColors.of(ctx);
    return AlertDialog(
      backgroundColor: c.surface,
      title: Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.text)),
      content: content,
      actions: actions,
    );
  }

  void _dialog(String title, String body) {
    showDialog<void>(
      context: context,
      builder: (ctx) => _alert(
        ctx,
        title: title,
        content: Text(
          body,
          style: TextStyle(fontSize: 13, height: 1.5, color: FindrColors.of(ctx).textSecondary),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('确定', style: TextStyle(color: FindrColors.of(ctx).record, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
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

  /// 版本展示串。**只显示版本号**，不再挂「（+构建号）」——
  /// 版本号现在就是三段 `X.Y.Z`、不带 `+N`，Android 的 versionCode 恒定是 1，
  /// 把它印出来只会让人以为还存在另一套编号。构建号仍参与「检查更新」的比较（见下）。
  String _versionLabel(RuntimeState rt) => rt.version ?? '1.0.0';

  /// 打开外部链接。**失败要说话** —— 静默失败会被当成「点了没反应」。
  Future<void> _openUrl(String url) async {
    var ok = false;
    try {
      ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) _toast('打不开浏览器，请手动访问：$url');
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted) setState(() {});
  }

  void _showDiagnosticsSheet() {
    final c = FindrColors.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Spacing.four, Spacing.three, Spacing.four, Spacing.five),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: Spacing.three),
                  decoration: BoxDecoration(
                    color: c.borderStrong,
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                ),
              ),
              Text(
                '处理队列与系统诊断',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.text),
              ),
              const SizedBox(height: Spacing.one),
              Text(
                '管理后台排队解析任务与设备运行状态自检',
                style: TextStyle(fontSize: 12, color: c.textMuted),
              ),
              const SizedBox(height: Spacing.four),
              FindrButton(
                title: '推进解析队列',
                variant: FindrButtonVariant.secondary,
                loading: _busy,
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _run((rt) async {
                    final res = await runQueueNow(rt);
                    if (res == null) return '尚未配置主模型，队列未执行。';
                    return '已处理 ${res.processed} 条，入库 ${res.settled} 条'
                        '${res.failed > 0 ? '，待重试 ${res.failed} 条' : ''}'
                        '${res.skippedNoAsr > 0 ? '，${res.skippedNoAsr} 条等待语音转写' : ''}。';
                  }, title: '处理队列');
                },
              ),
              const SizedBox(height: Spacing.two),
              FindrButton(
                title: '重试未完成的语音转写',
                variant: FindrButtonVariant.secondary,
                loading: _busy,
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _run((rt) async {
                    final res = await retryAllTranscriptions(requireDeps(rt));
                    await ref.read(runtimeProvider.notifier).refresh();
                    return '重置 ${res.reset} 条任务，已成功完成 ${res.run.settled} 条。';
                  }, title: '语音转写重试');
                },
              ),
              const SizedBox(height: Spacing.two),
              FindrButton(
                title: '运行系统诊断与自检',
                variant: FindrButtonVariant.ghost,
                icon: Icons.health_and_safety_outlined,
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _push(const SelfCheckScreen());
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDevDetails(RuntimeState rt) {
    final c = FindrColors.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: Text('系统信息', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.text)),
        content: SelectableText(
          '数据库文件：\n${rt.dbPath}\n\n'
          '版本号：${_versionLabel(rt)}\n'
          '图片处理：长边 ≤1600px，WebP 质量 0.8\n'
          '单卡图片上限：${rt.capture.maxAnalyzeImages} 张',
          style: TextStyle(fontSize: 12, height: 1.6, color: c.textSecondary),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('好', style: TextStyle(color: c.record)),
          ),
        ],
      ),
    );
  }

  /// 检查更新。**三态分别给三种说法**（理由见 `platform/update.dart` 文件头）——
  /// 「查不到」不许说成「已是最新」。
  Future<void> _checkUpdate(RuntimeState rt) async {
    final version = rt.version;
    if (version == null) {
      _dialog('检查更新', '暂时读不到当前版本号，稍后再试。');
      return;
    }
    setState(() => _busy = true);
    UpdateCheckResult res;
    try {
      res = await checkForUpdate(
        currentVersion: version,
        currentBuild: int.tryParse(rt.buildNumber ?? '') ?? 0,
      );
    } catch (_) {
      res = const UpdateCheckFailed();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    switch (res) {
      case UpdateAvailable(:final info):
        // 怎么更新（选源 → 应用内下载 → 安装）整个交给 update_flow，这里只管「查」
        unawaited(showUpdateFlow(context, ref, info: info, currentLabel: _versionLabel(rt)));
      case UpToDate():
        _dialog('检查更新', '当前已是最新版本 ${_versionLabel(rt)}。');
      case UpdateCheckFailed():
        _showUpdateFailedDialog();
    }
  }

  void _showUpdateFailedDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final c = FindrColors.of(ctx);
        return _alert(
          ctx,
          title: '检查更新',
          content: Text(
            '暂时拿不到更新信息（可能网络不稳）。\n可以稍后再试，或前往下载页手动查看。',
            style: TextStyle(fontSize: 13, height: 1.5, color: c.textSecondary),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _openUrl(releasePageUrl);
              },
              child: Text('前往下载页', style: TextStyle(color: c.record, fontWeight: FontWeight.w600)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('取消', style: TextStyle(color: c.textSecondary)),
            ),
          ],
        );
      },
    );
  }

  /// 开源仓库：GitHub / Gitee 两个入口，用系统浏览器打开。
  void _showRepoDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final c = FindrColors.of(ctx);
        return _alert(
          ctx,
          title: '开源仓库',
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _repoTile(ctx, name: 'GitHub', url: githubRepoUrl),
              const SizedBox(height: Spacing.two),
              _repoTile(ctx, name: 'Gitee', url: giteeRepoUrl),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('关闭', style: TextStyle(color: c.textSecondary)),
            ),
          ],
        );
      },
    );
  }

  Widget _repoTile(BuildContext ctx, {required String name, required String url}) {
    final c = FindrColors.of(ctx);
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.md),
      onTap: () {
        Navigator.of(ctx).pop();
        _openUrl(url);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.three, vertical: Spacing.three),
        decoration: BoxDecoration(
          color: c.surfaceSunken,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.code, size: 18, color: c.record),
            const SizedBox(width: Spacing.three),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.text)),
                  const SizedBox(height: 2),
                  Text(
                    url.replaceFirst(RegExp(r'^https?://'), ''),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: c.textMuted),
                  ),
                ],
              ),
            ),
            Icon(Icons.open_in_new_rounded, size: 18, color: c.textMuted),
          ],
        ),
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

    final llmName = rt.llm == null ? '未配置' : '${rt.llm!.model}（${rt.llm!.providerType.wire}）';
    final asrName = rt.asr?.model ?? '未配置';

    return Scaffold(
      appBar: FindrTopBar(title: '设置'),
      body: ScreenBody.column(
        padding: const EdgeInsets.fromLTRB(
          Spacing.four,
          Spacing.four,
          Spacing.four,
          Spacing.six,
        ),
        children: <Widget>[
          // ── 模型服务 ──────────────────────────────────
          Panel(
            title: '模型服务',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ListRow(
                  title: '主模型 (LLM)',
                  subtitle: llmName,
                  onTap: () => _push(const ProviderSettingsScreen(initialSlot: ProviderSlot.llm)),
                  right: Icon(Icons.chevron_right_rounded, size: 20, color: c.textMuted),
                ),
                FindrDivider(),
                ListRow(
                  title: '语音识别 (ASR)',
                  subtitle: asrName,
                  onTap: () => _push(const ProviderSettingsScreen(initialSlot: ProviderSlot.asr)),
                  right: Icon(Icons.chevron_right_rounded, size: 20, color: c.textMuted),
                ),
              ],
            ),
          ),

          // ── 智能偏好 ──────────────────────────────────
          Panel(
            title: '智能偏好',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ListRow(
                  title: '多模态图片分析',
                  subtitle: '录入图片时自动解析画面主体、细节与文字内容',
                  right: Switch(
                    value: rt.capture.visionDefault,
                    onChanged: (v) {
                      writeCaptureSettings(
                        rt.driver,
                        CaptureSettings(
                          visionDefault: v,
                          visionLast: rt.capture.visionLast,
                          maxAnalyzeImages: rt.capture.maxAnalyzeImages,
                        ),
                      );
                      ref.read(runtimeProvider.notifier).refresh();
                    },
                  ),
                ),
                FindrDivider(),
                ListRow(
                  title: '搜索智能解答',
                  subtitle: '检索时自动综合多条相关记忆并生成直接答复',
                  right: Switch(
                    value: rt.search.autoAnswer,
                    onChanged: (v) {
                      writeSearchSettings(rt.driver, SearchSettings(autoAnswer: v));
                      ref.read(runtimeProvider.notifier).refresh();
                    },
                  ),
                ),
              ],
            ),
          ),

          // ── 空间与分类 ──────────────────────────────────
          Panel(
            title: '空间与分类',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ListRow(
                  title: '空间位置树',
                  subtitle: '管理房间、家具与收纳容器',
                  onTap: () => _push(const LocationsScreen()),
                  right: Icon(Icons.chevron_right_rounded, size: 20, color: c.textMuted),
                ),
                FindrDivider(),
                ListRow(
                  title: '分类标签',
                  subtitle: '管理物品、证件、备忘等分类及标识',
                  onTap: () => _push(const CategoriesScreen()),
                  right: Icon(Icons.chevron_right_rounded, size: 20, color: c.textMuted),
                ),
              ],
            ),
          ),

          // ── 数据与维护 ──────────────────────────────────
          Panel(
            title: '数据与维护',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ListRow(
                  title: '数据备份与恢复',
                  subtitle: '导出或导入记忆档案包 (.findrpack)',
                  onTap: () => _push(const BackupScreen()),
                  right: Icon(Icons.chevron_right_rounded, size: 20, color: c.textMuted),
                ),
                FindrDivider(),
                ListRow(
                  title: '处理队列与诊断',
                  subtitle: '重试未完成的转写与模型解析，运行系统自检',
                  onTap: _showDiagnosticsSheet,
                  right: Icon(Icons.chevron_right_rounded, size: 20, color: c.textMuted),
                ),
              ],
            ),
          ),

          // ── 关于 ──────────────────────────────────────
          Panel(
            title: '关于 Findr',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: c.record,
                        borderRadius: BorderRadius.circular(Radii.md),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        'F',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: c.recordText),
                      ),
                    ),
                    const SizedBox(width: Spacing.three),
                    Expanded(
                      child: GestureDetector(
                        onLongPress: () => _showDevDetails(rt),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'FindR',
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.text),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '版本 ${_versionLabel(rt)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: c.textMuted),
                            ),
                          ],
                        ),
                      ),
                    ),
                    FindrButton(
                      title: '检查更新',
                      variant: FindrButtonVariant.secondary,
                      compact: true,
                      expand: false,
                      loading: _busy,
                      onPressed: () => _checkUpdate(rt),
                    ),
                  ],
                ),
                FindrDivider(),
                ListRow(
                  title: '开源仓库',
                  subtitle: '在 GitHub 或 Gitee 查看源码与发布',
                  onTap: _showRepoDialog,
                  right: Icon(Icons.chevron_right_rounded, size: 20, color: c.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
