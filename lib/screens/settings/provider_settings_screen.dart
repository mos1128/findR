/// 模型配置页。
///
/// 一个页面管两个槽位（主 LLM / ASR），用顶部的 Chip 切换。
/// 两者的字段几乎重合（地址 / 模型名 / Key），分成两页只会让「我到底该配哪个」更绕。
///
/// 三条口径：
///
/// 1. **Key 只写进系统密钥库**，不入 DB；支持明文/密文切换查看与修改。
///    （要不要随备份包带走，由备份页的开关决定 —— 这里不管。）
/// 2. **换了模型名，旧的探测结果就不再可信** —— 保存时要把 `capabilities` 丢掉。
///    否则界面会拿一个旧模型的结论去锁「图片分析」开关（需求 3.3 的反向误伤）。
/// 3. **「不支持」与「没测出来」必须分开说**。后者不是否定的证据，
///    用户不需要为它改配置，更不该因此被锁掉功能。
library;

import 'package:findr_core/findr_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/media.dart';
import '../../platform/runtime.dart';
import '../../platform/secure.dart';
import '../../theme/tokens.dart';
import '../../ui/kit.dart';

enum ProviderSlot { llm, asr }

class ProviderSettingsScreen extends ConsumerStatefulWidget {
  const ProviderSettingsScreen({
    super.key,
    this.initialSlot = ProviderSlot.llm,
  });

  final ProviderSlot initialSlot;

  @override
  ConsumerState<ProviderSettingsScreen> createState() => _ProviderSettingsScreenState();
}

class _ProviderSettingsScreenState extends ConsumerState<ProviderSettingsScreen> {
  late ProviderSlot _slot;
  ProviderType _providerType = ProviderType.anthropic;

  final _baseUrl = TextEditingController();
  final _model = TextEditingController();
  final _userAgent = TextEditingController();
  final _apiKey = TextEditingController();

  bool _busy = false;
  String? _probeText;
  bool _loaded = false;
  bool _obscureKey = true;

  @override
  void initState() {
    super.initState();
    _slot = widget.initialSlot;
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _model.dispose();
    _userAgent.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  /// 首次拿到运行时后把已存的值填进输入框。
  ///
  /// **只在第一次填**（`_loaded`）：否则用户改到一半、运行时因别处 refresh 而更新时，
  /// 输入框会被重新盖回旧值，看起来像「我打的字被吃了」。
  void _fillOnce(RuntimeState rt) {
    if (_loaded) return;
    _loaded = true;
    if (_slot == ProviderSlot.asr) {
      _baseUrl.text = rt.asr?.baseUrl ?? '';
      _model.text = rt.asr?.model ?? '';
      _apiKey.text = rt.asrKey ?? '';
    } else {
      final llm = rt.llm;
      _providerType = llm?.providerType ?? ProviderType.anthropic;
      _baseUrl.text = llm?.baseUrl ?? '';
      _model.text = llm?.model ?? '';
      _userAgent.text = llm?.userAgent ?? '';
      _apiKey.text = rt.llmKey ?? '';
    }
  }

  RuntimeState get _rt {
    final v = ref.read(runtimeProvider).value;
    if (v == null) throw StateError('运行时还没就绪');
    return v;
  }

  void _switchSlot(ProviderSlot next) {
    if (next == _slot) return;
    final rt = _rt;
    _slot = next;
    // 切槽位时把字段换成那个槽位的当前值 —— 两个槽位的地址/模型名通常完全不同，
    // 留着上一个框里的内容会让人误以为「没保存上」
    if (next == ProviderSlot.llm) {
      _baseUrl.text = rt.llm?.baseUrl ?? '';
      _model.text = rt.llm?.model ?? '';
      _providerType = rt.llm?.providerType ?? ProviderType.anthropic;
      _userAgent.text = rt.llm?.userAgent ?? '';
      _apiKey.text = rt.llmKey ?? '';
    } else {
      _baseUrl.text = rt.asr?.baseUrl ?? '';
      _model.text = rt.asr?.model ?? '';
      _apiKey.text = rt.asrKey ?? '';
    }
    _probeText = null;
    setState(() {});
  }

  LlmSettings _buildLlm(RuntimeState rt, {bool keepCaps = true}) {
    final model = _model.text.trim();
    CapabilityCache? caps = rt.llm?.capabilities;
    // 换了模型，旧结论作废（见文件头第 2 条）
    if (!keepCaps || (caps != null && caps.probedModel != model)) caps = null;
    return LlmSettings(
      providerType: _providerType,
      baseUrl: _baseUrl.text.trim().isEmpty ? null : _baseUrl.text.trim(),
      model: model,
      userAgent: _userAgent.text.trim().isEmpty ? null : _userAgent.text.trim(),
      capabilities: caps,
    );
  }

  AsrSettings _buildAsr() => AsrSettings(
    model: _model.text.trim(),
    baseUrl: _baseUrl.text.trim().isEmpty ? null : _baseUrl.text.trim(),
  );

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _probeText = null;
    });
    try {
      final rt = _rt;
      final key = _apiKey.text.trim();
      await ref.read(apiKeyStoreProvider).write(
        _slot == ProviderSlot.llm ? ApiKeySlot.llm : ApiKeySlot.asr,
        key,
      );
      if (_slot == ProviderSlot.llm) {
        writeLlmSettings(rt.driver, _buildLlm(rt));
      } else {
        writeAsrSettings(rt.driver, _buildAsr());
      }
      await ref.read(runtimeProvider.notifier).refresh();
      if (!mounted) return;
      _toast('已保存');
    } catch (e) {
      if (mounted) _toast('保存失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _probe() async {
    setState(() {
      _busy = true;
      _probeText = null;
    });
    try {
      final rt = _rt;
      final key = _apiKey.text.trim().isNotEmpty ? _apiKey.text.trim() : null;
      if (_slot == ProviderSlot.llm) {
        final cfg = _buildLlm(rt, keepCaps: false);
        final adapter = makeLlmAdapter(cfg);
        final stored = key ?? rt.llmKey;
        final caps = await probeLlm(adapter, toProviderConfig(cfg, stored));
        writeLlmSettings(
          rt.driver,
          LlmSettings(
            providerType: cfg.providerType,
            baseUrl: cfg.baseUrl,
            model: cfg.model,
            userAgent: cfg.userAgent,
            capabilities: CapabilityCache(
              text: caps.text,
              textDetail: caps.textDetail,
              vision: caps.vision,
              visionDetail: caps.visionDetail,
              visionStatus: caps.visionStatus,
              // ⚠️ 必须用 isoUtc()，与库里其余时间列同口径
              probedAt: isoUtc(DateTime.now()),
              probedModel: cfg.model,
            ),
          ),
        );
        await ref.read(runtimeProvider.notifier).refresh();
        if (!mounted) return;
        setState(() => _probeText = _probeSummary(caps));
      } else {
        final cfg = _buildAsr();
        final adapter = makeAsrAdapter(cfg, const DeviceMediaIo());
        final stored = key ?? rt.asrKey;
        // 用内嵌的 1 秒 WAV 试转一次，能返回就算通了
        final res = await adapter.transcribe(
          TranscribeRequest(
            audio: AudioBase64Ref(base64: testWavBase64(), mime: 'audio/wav'),
            filename: 'probe.wav',
            timeoutMs: 60000,
          ),
          toAsrProviderConfig(cfg, stored),
        );
        if (!mounted) return;
        setState(() => _probeText = '● ASR 语音识别：正常 — 返回：${res.text.isEmpty ? '（空音频正常连通）' : res.text}');
      }
    } catch (e) {
      if (mounted) setState(() => _probeText = '○ 检测失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

  @override
  Widget build(BuildContext context) {
    final rt = ref.watch(runtimeProvider).value;
    if (rt == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    _fillOnce(rt);
    final c = FindrColors.of(context);
    final isLlm = _slot == ProviderSlot.llm;

    return Scaffold(
      appBar: FindrTopBar(title: isLlm ? '主模型配置' : '语音识别配置'),
      body: ScreenBody.column(
        padding: const EdgeInsets.fromLTRB(
          Spacing.four,
          Spacing.four,
          Spacing.four,
          Spacing.six,
        ),
        children: <Widget>[
          Panel(
            title: '配置目标服务',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    FindrChip(
                      label: '主语言与多模态模型',
                      active: isLlm,
                      onPressed: () => _switchSlot(ProviderSlot.llm),
                    ),
                    const SizedBox(width: Spacing.two),
                    FindrChip(
                      label: '语音识别 (ASR)',
                      active: !isLlm,
                      onPressed: () => _switchSlot(ProviderSlot.asr),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.three),
                Text(
                  isLlm
                      ? '主模型负责多模态图像理解、卡片总结生成与结构抽取。'
                      : '语音识别服务为可选配置，负责录音自动转写为文字。',
                  style: TextStyle(fontSize: 11.5, height: 1.45, color: c.textMuted),
                ),
              ],
            ),
          ),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (isLlm) ...<Widget>[
                  const SectionTitle('协议格式'),
                  const SizedBox(height: Spacing.two),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: <Widget>[
                        FindrChip(
                          label: 'Anthropic',
                          active: _providerType == ProviderType.anthropic,
                          onPressed: () => setState(() => _providerType = ProviderType.anthropic),
                        ),
                        const SizedBox(width: Spacing.two),
                        FindrChip(
                          label: 'OpenAI chat',
                          active: _providerType == ProviderType.openaiCompat,
                          onPressed: () =>
                              setState(() => _providerType = ProviderType.openaiCompat),
                        ),
                        const SizedBox(width: Spacing.two),
                        FindrChip(
                          label: 'OpenAI response',
                          active: _providerType == ProviderType.openaiResponses,
                          onPressed: () =>
                              setState(() => _providerType = ProviderType.openaiResponses),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Spacing.three),
                ],
                FindrField(
                  label: '服务地址 (Base URL)',
                  controller: _baseUrl,
                  keyboardType: TextInputType.url,
                  placeholder: isLlm
                      ? (_providerType == ProviderType.anthropic
                          ? 'https://api.anthropic.com'
                          : 'https://api.openai.com')
                      : 'https://api.openai.com',
                  hint: '支持公网 API 接口或局域网反向代理服务地址',
                ),
                const SizedBox(height: Spacing.four),
                FindrField(
                  label: '模型名称',
                  controller: _model,
                  placeholder: isLlm
                      ? (_providerType == ProviderType.anthropic
                          ? 'claude-3-5-sonnet-20241022'
                          : 'gpt-4o')
                      : 'whisper-1',
                ),
                const SizedBox(height: Spacing.four),
                FindrField(
                  label: 'API Key',
                  controller: _apiKey,
                  obscure: _obscureKey,
                  placeholder: 'sk-...',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureKey ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                      size: 20,
                      color: c.textMuted,
                    ),
                    tooltip: _obscureKey ? '显示明文' : '隐藏明文',
                    onPressed: () => setState(() => _obscureKey = !_obscureKey),
                  ),
                ),
                if (isLlm) ...<Widget>[
                  const SizedBox(height: Spacing.four),
                  FindrField(
                    label: 'User-Agent（可选）',
                    controller: _userAgent,
                    placeholder: 'Findr/1.0',
                    hint: '自定义客户端标识头，通常保持为空即可',
                  ),
                ],
              ],
            ),
          ),
          Panel(
            title: '服务连通性与能力检测',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                FindrButton(
                  title: '开始检测连接',
                  variant: FindrButtonVariant.secondary,
                  loading: _busy,
                  onPressed: () => _probe(),
                ),
                if (_probeText != null) ...<Widget>[
                  const SizedBox(height: Spacing.three),
                  Container(
                    decoration: BoxDecoration(
                      color: c.surfaceAlt,
                      borderRadius: BorderRadius.circular(Radii.sm),
                    ),
                    padding: const EdgeInsets.all(Spacing.three),
                    child: Text(
                      _probeText!,
                      style: TextStyle(fontSize: 12.5, height: 1.5, color: c.textSecondary),
                    ),
                  ),
                ],
              ],
            ),
          ),
          FindrButton(
            title: '保存配置',
            loading: _busy,
            onPressed: () => _save(),
          ),
        ],
      ),
    );
  }

  /// 探测结果摘要。顺序刻意如此：**先说「配置本身对不对」**（用户最想知道的），再说图片能力。
  String _probeSummary(ProbedCapabilities caps) {
    final connectivity = caps.text
        ? '● 接口连通：正常 — ${caps.textDetail}'
        : '○ 接口连通：失败 — ${caps.textDetail}';
    final vision = switch (caps.visionStatus) {
      CapabilityStatus.ok => '● 图像分析：支持 — ${caps.visionDetail}',
      CapabilityStatus.unsupported => '○ 图像分析：不支持 — ${caps.visionDetail}',
      CapabilityStatus.unknown => '- 图像分析：未明确响应 — ${caps.visionDetail}',
      _ => caps.vision
          ? '● 图像分析：支持 — ${caps.visionDetail}'
          : '○ 图像分析：不支持 — ${caps.visionDetail}',
    };
    final tail = caps.text
        ? ''
        : '\n\n排查提示：请核对接口地址 (Base URL)、API Key 与模型名称是否正确。';
    return '$connectivity\n$vision$tail';
  }
}
