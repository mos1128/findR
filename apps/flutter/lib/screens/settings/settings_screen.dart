/// 设置主页 —— 对应 RN 的 `app/settings/index.tsx`。
///
/// 分七块：模型 / 录入 / 检索 / 词表 / 数据 / 维护 / 关于。
/// 版式是新画的，但**每一条提示语都保留** —— 那些话是在真机上踩过坑之后留下来的
/// （比如「关掉图片分析省 token，但图中内容搜不到」），少一句用户就会少一个判断依据。
library;

import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/runtime.dart';
import '../../platform/secure.dart';
import '../../selfcheck/self_check_screen.dart';
import '../../theme/tokens.dart';
import '../../ui/kit.dart';
import 'backup_screen.dart';
import 'categories_screen.dart';
import 'locations_screen.dart';
import 'provider_settings_screen.dart';

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

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted) setState(() {});
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
          Panel(
            title: '模型',
            hint: 'BYOK：模型与 Key 都由你自己提供',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ListRow(
                  title: '主 LLM',
                  subtitle: llmName,
                  onTap: () => _push(const ProviderSettingsScreen()),
                  right: Icon(Icons.chevron_right_rounded, size: 20, color: c.textMuted),
                ),
                FindrDivider(),
                ListRow(
                  title: 'ASR（语音转写）',
                  subtitle: asrName,
                  onTap: () => _push(const ProviderSettingsScreen()),
                  right: Icon(Icons.chevron_right_rounded, size: 20, color: c.textMuted),
                ),
                const SizedBox(height: Spacing.two),
                Text(
                  'API Key 存在系统密钥库，不进数据库、也不会出现在导出备份里。'
                  '当前：LLM ${maskApiKey(rt.llmKey)} / ASR ${maskApiKey(rt.asrKey)}',
                  style: TextStyle(fontSize: 11.5, height: 1.45, color: c.textMuted),
                ),
              ],
            ),
          ),
          Panel(
            title: '录入',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ListRow(
                  title: '图片分析默认值',
                  subtitle: '每次录入仍可临时切换；关掉可省 token，但图中内容搜不到',
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
                if (rt.capture.visionLast != null) ...<Widget>[
                  FindrDivider(),
                  ListRow(
                    title: '上次的选择',
                    subtitle: '最近一次录入用的是「${rt.capture.visionLast! ? '开' : '关'}」，点这里恢复成跟随默认值',
                    onTap: () {
                      writeCaptureSettings(
                        rt.driver,
                        CaptureSettings(
                          visionDefault: rt.capture.visionDefault,
                          visionLast: null,
                          maxAnalyzeImages: rt.capture.maxAnalyzeImages,
                        ),
                      );
                      ref.read(runtimeProvider.notifier).refresh();
                    },
                    right: Text('重置', style: TextStyle(fontSize: 13, color: c.record)),
                  ),
                ],
                const SizedBox(height: Spacing.two),
                Text(
                  '单卡最多送模型分析 ${rt.capture.maxAnalyzeImages} 张图（固定护栏，超出的图片仍会保存）',
                  style: TextStyle(fontSize: 11.5, height: 1.45, color: c.textMuted),
                ),
              ],
            ),
          ),
          Panel(
            title: '检索',
            hint: '每次搜索要不要顺手让模型写一段答案',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ListRow(
                  title: '每次搜索都自动组织答案',
                  subtitle: '关：只在搜不到、或你点「AI 总结」时才跑。开：搜到也自动跑，答案追加在列表下方',
                  right: Switch(
                    value: rt.search.autoAnswer,
                    onChanged: (v) {
                      writeSearchSettings(rt.driver, SearchSettings(autoAnswer: v));
                      ref.read(runtimeProvider.notifier).refresh();
                    },
                  ),
                ),
                const SizedBox(height: Spacing.two),
                Text(
                  '打开后每次搜索都会把最多 8 条命中片段发给模型；真正的代价是 —— '
                  '关着的时候你不点按钮就不外发任何记忆内容，开着则每次搜索都会。',
                  style: TextStyle(fontSize: 11.5, height: 1.45, color: c.textMuted),
                ),
              ],
            ),
          ),
          Panel(
            title: '词表',
            hint: '位置是检索质量的命脉',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ListRow(
                  title: '位置树',
                  subtitle: '房间 → 家具 → 容器',
                  onTap: () => _push(const LocationsScreen()),
                  right: Icon(Icons.chevron_right_rounded, size: 20, color: c.textMuted),
                ),
                FindrDivider(),
                ListRow(
                  title: '分类',
                  subtitle: '名称、Emoji、给模型看的识别描述',
                  onTap: () => _push(const CategoriesScreen()),
                  right: Icon(Icons.chevron_right_rounded, size: 20, color: c.textMuted),
                ),
              ],
            ),
          ),
          Panel(
            title: '数据',
            hint: '换机、重装靠它把记忆搬回去',
            child: ListRow(
              title: '备份与恢复',
              subtitle: '导出明文文件（不加密、不含 API Key），也能从备份合并回来',
              onTap: () => _push(const BackupScreen()),
              right: Icon(Icons.chevron_right_rounded, size: 20, color: c.textMuted),
            ),
          ),
          Panel(
            title: '维护',
            hint: '配置好 ASR 后用它把积压的语音一次补完',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                FindrButton(
                  title: '批量补转写',
                  variant: FindrButtonVariant.secondary,
                  loading: _busy,
                  onPressed: () => _run((rt) async {
                    final res = await retryAllTranscriptions(requireDeps(rt));
                    await ref.read(runtimeProvider.notifier).refresh();
                    return '重置 ${res.reset} 张，完成 ${res.run.settled} 张。';
                  }, title: '补转写'),
                ),
                const SizedBox(height: Spacing.two),
                FindrButton(
                  title: '立刻跑一次解析队列',
                  variant: FindrButtonVariant.secondary,
                  onPressed: () => _run((rt) async {
                    final res = await runQueueNow(rt);
                    if (res == null) return '还没配置主模型，队列没跑。素材都在，配好之后会自动补上。';
                    return '推进 ${res.processed} 张，入库 ${res.settled} 张'
                        '${res.failed > 0 ? '，失败 ${res.failed} 张（卡片上带「重试中」，可再跑一次）' : ''}'
                        '${res.skippedNoAsr > 0 ? '，${res.skippedNoAsr} 张在等 ASR' : ''}。';
                  }, title: '跑队列'),
                ),
                const SizedBox(height: Spacing.two),
                FindrButton(
                  title: '打开自检',
                  variant: FindrButtonVariant.ghost,
                  icon: Icons.health_and_safety_outlined,
                  onPressed: () => _push(const SelfCheckScreen()),
                ),
              ],
            ),
          ),
          Panel(
            title: '关于',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    FindrChip(
                      dense: true,
                      label:
                          '图片分析${rt.llm?.capabilities == null ? '：未探测' : (rt.llm!.capabilities!.vision ? '：支持' : '：不支持')}',
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.three),
                Text(
                  '数据库：${rt.dbPath}\n'
                  '版本：${rt.version ?? '未知'}\n'
                  '图片压缩参数：长边 ≤1600px、WebP 0.8（默认：图片分析'
                  '${defaultCaptureSettings.visionDefault ? '开' : '关'}）',
                  style: TextStyle(fontSize: 11.5, height: 1.6, color: c.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
