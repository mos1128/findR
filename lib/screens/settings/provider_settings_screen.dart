/// 模型配置页。
///
/// 一个页面管两个槽位（主 LLM / ASR），用顶部的 Chip 切换。
/// 两者的字段几乎重合（地址 / 模型名 / Key），分成两页只会让「我到底该配哪个」更绕。
///
/// 三条口径：
///
/// 1. **Key 只写进系统密钥库**，不入 DB；输入框留空 = 不改动已存的那把。
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

enum _Slot { llm, asr }

class ProviderSettingsScreen extends ConsumerStatefulWidget {
  const ProviderSettingsScreen({super.key});

  @override
  ConsumerState<ProviderSettingsScreen> createState() => _ProviderSettingsScreenState();
}

class _ProviderSettingsScreenState extends ConsumerState<ProviderSettingsScreen> {
  _Slot _slot = _Slot.llm;
  ProviderType _providerType = ProviderType.anthropic;

  final _baseUrl = TextEditingController();
  final _model = TextEditingController();
  final _userAgent = TextEditingController();
  final _apiKey = TextEditingController();

  bool _busy = false;
  String? _probeText;
  bool _loaded = false;

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
    final llm = rt.llm;
    _providerType = llm?.providerType ?? ProviderType.anthropic;
    _baseUrl.text = llm?.baseUrl ?? rt.asr?.baseUrl ?? '';
    _model.text = llm?.model ?? rt.asr?.model ?? '';
    _userAgent.text = llm?.userAgent ?? '';
  }

  RuntimeState get _rt {
    final v = ref.read(runtimeProvider).value;
    if (v == null) throw StateError('运行时还没就绪');
    return v;
  }

  void _switchSlot(_Slot next) {
    if (next == _slot) return;
    final rt = _rt;
    _slot = next;
    // 切槽位时把字段换成那个槽位的当前值 —— 两个槽位的地址/模型名通常完全不同，
    // 留着上一个框里的内容会让人误以为「没保存上」
    if (next == _Slot.llm) {
      _baseUrl.text = rt.llm?.baseUrl ?? '';
      _model.text = rt.llm?.model ?? '';
      _providerType = rt.llm?.providerType ?? ProviderType.anthropic;
    } else {
      _baseUrl.text = rt.asr?.baseUrl ?? '';
      _model.text = rt.asr?.model ?? '';
    }
    _apiKey.clear();
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

  Future<void> _save({bool thenDrain = false}) async {
    setState(() {
      _busy = true;
      _probeText = null;
    });
    try {
      final rt = _rt;
      final key = _apiKey.text.trim();
      if (key.isNotEmpty) {
        await ref.read(apiKeyStoreProvider).write(
          _slot == _Slot.llm ? ApiKeySlot.llm : ApiKeySlot.asr,
          key,
        );
        _apiKey.clear();
      }
      if (_slot == _Slot.llm) {
        writeLlmSettings(rt.driver, _buildLlm(rt));
      } else {
        writeAsrSettings(rt.driver, _buildAsr());
      }
      await ref.read(runtimeProvider.notifier).refresh();
      if (!mounted) return;
      _toast('已保存');
      if (thenDrain) {
        // 刚配好模型，顺手把积压的草稿推一遍 —— 这是用户配完之后最想看到的事
        final ok = await runQueueNow(_rt);
        if (mounted) {
          _toast(ok == null ? '保存了，但还没配好主模型' : '已保存，并跑了一次解析队列');
        }
      }
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
      if (_slot == _Slot.llm) {
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
        setState(() => _probeText = 'ASR 可用，返回：${res.text.isEmpty ? '（空文本，仍算连通）' : res.text}');
      }
    } catch (e) {
      if (mounted) setState(() => _probeText = '探测失败：$e');
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
    final isLlm = _slot == _Slot.llm;
    final currentKey = isLlm ? rt.llmKey : rt.asrKey;

    return Scaffold(
      appBar: FindrTopBar(title: '模型配置'),
      body: ScreenBody.column(
        padding: const EdgeInsets.fromLTRB(
          Spacing.four,
          Spacing.four,
          Spacing.four,
          Spacing.six,
        ),
        children: <Widget>[
          Panel(
            title: '配置哪个槽位',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    FindrChip(
                      label: '主 LLM',
                      active: isLlm,
                      onPressed: () => _switchSlot(_Slot.llm),
                    ),
                    const SizedBox(width: Spacing.two),
                    FindrChip(
                      label: 'ASR',
                      active: !isLlm,
                      onPressed: () => _switchSlot(_Slot.asr),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.three),
                Text(
                  isLlm
                      ? '主模型负责图片理解、描述生成与结构抽取。没有图片能力的模型也能用，图片会降级成纯附件。'
                      : 'ASR 是可选的。不配也能用：语音会先存着，之后补一句话即可。',
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
                  const SectionTitle('协议'),
                  const SizedBox(height: Spacing.two),
                  Row(
                    children: <Widget>[
                      FindrChip(
                        label: 'Anthropic',
                        active: _providerType == ProviderType.anthropic,
                        onPressed: () => setState(() => _providerType = ProviderType.anthropic),
                      ),
                      const SizedBox(width: Spacing.two),
                      FindrChip(
                        label: 'OpenAI 兼容',
                        active: _providerType == ProviderType.openaiCompat,
                        onPressed: () =>
                            setState(() => _providerType = ProviderType.openaiCompat),
                      ),
                    ],
                  ),
                  const SizedBox(height: Spacing.three),
                ],
                FindrField(
                  label: 'Base URL',
                  controller: _baseUrl,
                  keyboardType: TextInputType.url,
                  placeholder: isLlm ? 'http://192.168.1.9:7788' : 'https://api.openai.com',
                  hint: '局域网网关请填 PC 的局域网 IP；手机要与 PC 在同一个 Wi-Fi 下',
                ),
                const SizedBox(height: Spacing.four),
                FindrField(
                  label: '模型名',
                  controller: _model,
                  placeholder: isLlm ? 'claude-opus-5' : 'whisper-1',
                ),
                if (isLlm) ...<Widget>[
                  const SizedBox(height: Spacing.four),
                  FindrField(
                    label: 'User-Agent（可选）',
                    controller: _userAgent,
                    placeholder: 'claude-cli/2.1.268 (external, cli)',
                    hint: '部分网关按 UA 路由，需要伪装成已知客户端',
                  ),
                ],
                const SizedBox(height: Spacing.four),
                FindrField(
                  label: 'API Key',
                  controller: _apiKey,
                  obscure: true,
                  placeholder: currentKey != null && currentKey.isNotEmpty
                      ? '已保存（${maskApiKey(currentKey)}），留空则不变'
                      : 'sk-...',
                  hint: '只写入系统密钥库，不入数据库',
                ),
              ],
            ),
          ),
          Panel(
            title: '连通性 / 能力探测',
            hint: isLlm ? '发纯文本与一张 64×64 测试图各试一次' : '发一段 1 秒测试音频试转',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                FindrButton(
                  title: '开始探测',
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
                if (isLlm && rt.llm?.capabilities != null) ...<Widget>[
                  const SizedBox(height: Spacing.three),
                  Text(
                    '上次探测（${rt.llm!.capabilities!.probedModel}，'
                    '${rt.llm!.capabilities!.probedAt.length >= 19 ? rt.llm!.capabilities!.probedAt.substring(0, 19) : rt.llm!.capabilities!.probedAt}）：'
                    '配置${_capsMark(rt.llm!.capabilities!.text)}、'
                    '图片${_capsMark(rt.llm!.capabilities!.vision)}',
                    style: TextStyle(fontSize: 11.5, height: 1.5, color: c.textMuted),
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
          FindrButton(
            title: '保存并立刻补跑一次队列',
            variant: FindrButtonVariant.secondary,
            onPressed: () => _save(thenDrain: true),
          ),
        ],
      ),
    );
  }

  /// 布尔 → 一个符号；旧缓存里没记录的项目显示「未记录」，**别装成「不支持」**。
  String _capsMark(bool? ok) {
    if (ok == null) return '未记录';
    return ok ? '✅' : '⬜';
  }

  /// 探测结果摘要。顺序刻意如此：**先说「配置本身对不对」**（用户最想知道的），再说图片能力。
  ///
  /// 刻意**不测**「主模型能否听音频」：那条路从来没有被业务代码走过（转写始终只走 ASR 槽），
  /// 测一个不存在的功能只会让用户在设置页看到一句误导的「不支持」。
  String _probeSummary(ProbedCapabilities caps) {
    final connectivity = caps.text
        ? '✅ 配置连通性：可用 —— ${caps.textDetail}'
        : '⬜ 配置连通性：不可用 —— ${caps.textDetail}';
    final vision = switch (caps.visionStatus) {
      CapabilityStatus.ok => '✅ 图片分析：可用 —— ${caps.visionDetail}',
      CapabilityStatus.unsupported => '⬜ 图片分析：不支持 —— ${caps.visionDetail}',
      CapabilityStatus.unknown => '⬜ 图片分析：没测出来 —— ${caps.visionDetail}',
      _ => caps.vision
          ? '✅ 图片分析：可用 —— ${caps.visionDetail}'
          : '⬜ 图片分析：不可用 —— ${caps.visionDetail}',
    };
    final tail = caps.text
        ? ''
        : '\n\n先解决第一条：地址 / Key / 模型名有问题，与模型能力无关。';
    return '$connectivity\n$vision$tail';
  }
}
