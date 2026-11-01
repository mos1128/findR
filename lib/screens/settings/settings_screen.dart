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
import '../../state/update_check.dart';
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

  /// GitHub 加速地址输入框（初值在第一次拿到运行时快照时填入，见 build）。
  final _accelCtrl = TextEditingController();
  bool _accelInited = false;

  @override
  void dispose() {
    _accelCtrl.dispose();
    super.dispose();
  }

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
      if (mounted) _dialog(title == null ? '失败' : '$title失败', plainError(e));
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
                '处理排队任务与设备自检',
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
                    // 没配主模型时 requireDeps 会抛，这里先挡一道 —— 两条队列入口的提示要一致，
                    // 否则会出现「推进队列」说人话、「语音转写重试」却甩出 Bad state。
                    if (!llmConfigured(rt.llm)) return '尚未配置主模型，转写未执行。';
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
        // 手动查到的结果同样记下来：首页红点跟着它走，不会说反话
        recordUpdateCheck(ref.read(dbProvider), latestTag: info.tag);
        ref.invalidate(updateHintProvider);
        // 怎么更新（选源 → 应用内下载 → 安装）整个交给 update_flow，这里只管「查」
        unawaited(showUpdateFlow(context, ref, info: info, currentLabel: _versionLabel(rt)));
      case UpToDate():
        recordUpdateCheck(ref.read(dbProvider), latestTag: null);
        ref.invalidate(updateHintProvider);
        _dialog('检查更新', '已是最新版本 ${_versionLabel(rt)}。');
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
            '拿不到更新信息（可能网络不稳）。\n稍后再试，或前往下载页。',
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

    // 首页齿轮上那个点的含义靠这一行补上：进了设置页，「检查更新」上也有同一个点。
    // 只用 `value`：静默检查还没回来时不打点，别让用户白跑一趟。
    final updateTag = ref.watch(updateHintProvider).value;
    final hasUpdate = updateTag != null;

    // 加速设置是本机偏好，直接读写 settings 表（不经过运行时快照，改完立即可用）
    final accelEnabled = readUpdateAccelEnabled(rt.driver);
    if (!_accelInited) {
      _accelCtrl.text = readUpdateAccelPrefix(rt.driver);
      _accelInited = true;
    }

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
                  subtitle: '录入图片时自动解析画面与文字',
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
                  subtitle: '检索时综合多条记忆，直接给答复',
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
                  subtitle: '导出或导入档案包 (.findrpack)',
                  onTap: () => _push(const BackupScreen()),
                  right: Icon(Icons.chevron_right_rounded, size: 20, color: c.textMuted),
                ),
                FindrDivider(),
                ListRow(
                  title: '处理队列与诊断',
                  subtitle: '重试转写与解析，运行自检',
                  onTap: _showDiagnosticsSheet,
                  right: Icon(Icons.chevron_right_rounded, size: 20, color: c.textMuted),
                ),
              ],
            ),
          ),

          // ── 关于 ──────────────────────────────────────
          // 整块都用 ListRow：和上面那些块一个节奏（标题 + 副标题 + 右侧箭头）。
          // 以前「检查更新」是一枚塞在身份行右边的实心按钮 —— 它是这一屏里唯一的按钮，
          // 行高和别的行不一样，看着就"没对齐"（真机反馈）。改成一行之后自然齐了。
          Panel(
            title: '关于 Findr',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ListRow(
                  leading: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: c.record,
                      borderRadius: BorderRadius.circular(Radii.md),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      'F',
                      style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: c.recordText),
                    ),
                  ),
                  title: 'Findr',
                  subtitle: '版本 ${_versionLabel(rt)}',
                  onLongPress: () => _showDevDetails(rt),
                ),
                FindrDivider(),
                ListRow(
                  title: '检查更新',
                  // 已经知道有新版本时，就别再让用户「看看有没有」了 —— 直接把版本报出来
                  // （红点只有配上这句话才不靠猜）。
                  subtitle: _busy
                      ? '正在检查…'
                      : hasUpdate
                          ? '发现新版本 $updateTag'
                          : '检查是否有新版本',
                  onTap: _busy ? null : () => _checkUpdate(rt),
                  right: _busy
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: c.record),
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            if (hasUpdate) ...<Widget>[
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(color: c.danger, shape: BoxShape.circle),
                              ),
                              const SizedBox(width: Spacing.two),
                            ],
                            Icon(Icons.chevron_right_rounded, size: 20, color: c.textMuted),
                          ],
                        ),
                ),
                FindrDivider(),
                ListRow(
                  title: 'GitHub 下载加速',
                  right: Switch(
                    value: accelEnabled,
                    onChanged: (v) {
                      writeUpdateAccel(rt.driver, enabled: v, prefix: _accelCtrl.text);
                      ref.invalidate(updateAccelPrefixProvider);
                      setState(() {});
                    },
                  ),
                ),
                if (accelEnabled)
                  // 左右用 Spacing.two：ListRow 的横向内边距就是 8，
                  // 合起来才和上面的「GitHub 下载加速」「开源仓库」左右对齐（真机反馈）。
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Spacing.two,
                      Spacing.two,
                      Spacing.two,
                      Spacing.three,
                    ),
                    child: FindrField(
                      label: '加速地址',
                      controller: _accelCtrl,
                      placeholder: 'https://gh-proxy.com/',
                      onChanged: (v) {
                        writeUpdateAccel(rt.driver, enabled: true, prefix: v);
                        ref.invalidate(updateAccelPrefixProvider);
                      },
                    ),
                  ),
                FindrDivider(),
                ListRow(
                  title: '开源仓库',
                  subtitle: '在 GitHub / Gitee 看源码与发布',
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
