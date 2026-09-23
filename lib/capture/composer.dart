/// 底部录入条 —— 对应 RN 的 `capture/Composer.tsx`（383 行）。
///
/// **这是「记」的唯一入口**（需求六）：打字 / 拍照 / 相册 / 文本文件 / 长按语音全在这一条里，
/// 不再有「两个按钮通到同一个页面」那种事。
///
/// 与 RN 版比，版式是新画的：底部做成一整块「坞」（圆角 + 上浮阴影），
/// 打字框与「存」不再分成两个视觉单元 —— 「记」是**一条**链路，
/// 界面上就不该长得像两个并列的功能。
///
/// 三条不容易写对的口径：
///
/// 1. **「存」的亮灭要自己记住上一次的值**（`_hadText`）——
///    写成 `if (has != _canSubmit) setState(...)` 会静默失效，因为 `_canSubmit`
///    读的就是同一个 controller，新旧值永远相等，`setState` 一次都不触发。
///    （这个 bug 被 `test/memory_stream_test.dart` 抓过。）
/// 2. **图片在「选中的那一刻」就压好**，不是等到按「存」。
///    压一张 1600px 要几百毫秒，攒到按「存」时再压，用户会盯着一个转圈怀疑是不是卡了。
///    代价是选图后要等一小会儿 —— 所以那段时间有明确的「正在处理 2/5」。
/// 3. **录音按键用裸指针事件**（`Listener`），不是 `onLongPress`。
///    与 RN 的 `onPressIn/onPressOut` 对齐：按下即录、松开即结束，
///    太短由 [shouldDiscardRecording] 判为误触丢掉，**不弹窗、不生成空卡**。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../platform/app_paths.dart';
import '../theme/tokens.dart';
import '../ui/kit.dart';
import 'image_compress.dart';
import 'photo_picker.dart';
import 'recorder.dart';
import 'submit.dart';
import 'text_file.dart';

/// 一条待录入的内容。
final class ComposerPayload {
  const ComposerPayload({
    this.text = '',
    this.photos = const <PendingPhoto>[],
    this.audio,
    this.fromFile = false,
    this.vision = true,
    this.visionOverride,
  });

  final String text;

  /// 已经压好的图片（顺序即拍摄/选择顺序）。
  final List<PendingPhoto> photos;

  /// 录音；`null` 表示这次没有语音。
  final RecordedAudio? audio;

  /// 文本来源里有没有「选文件」那一份。只影响提示文案。
  final bool fromFile;

  /// 本次录入的图片分析开关最终取值。
  final bool vision;

  /// 用户在这一次里**手动切过**吗。切过才需要写回设置里的 `visionLast`（需求 5.1）。
  final bool? visionOverride;
}

class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.onSubmit,
    this.enabled = true,

    /// 提交期间禁用整条（避免连点存出一堆重复卡）。
    this.busy = false,

    /// 上方要贴的提示（无网 / 未配 ASR 那类）。**放在坞的上边缘之内**，
    /// 与录入条同属一个视觉块，用户不会以为它是页面内容。
    this.notice,

    /// 当前模型有没有视觉能力。没有的话「图片分析」开关锁定为「不可用」。
    this.visionCapable = true,

    /// 设置里的默认值（`effectiveVision(capture, capable)` 的结果）。
    this.visionDefault = true,
  });

  final Future<void> Function(ComposerPayload payload) onSubmit;
  final bool enabled;
  final bool busy;
  final Widget? notice;
  final bool visionCapable;
  final bool visionDefault;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _recorder = LongPressRecorder();

  bool _sending = false;

  /// 「存」按钮的亮灭只取决于「手里有没有内容」。见文件头第 1 条。
  bool _hadContent = false;

  final _photos = <PendingPhoto>[];
  final _files = <TextFileOk>[];
  RecordedAudio? _audio;

  /// 正在压缩第几张 / 一共几张。0 表示没在处理。
  int _processingDone = 0;
  int _processingTotal = 0;

  bool _expanded = false;
  bool _recording = false;
  Timer? _ticker;

  /// `null` = 跟随设置；非 null = 用户这一次手动切过（需求 5.1）。
  bool? _visionOverride;

  bool get _vision => _visionOverride ?? widget.visionDefault;

  static bool _cachedVoiceMode = false;
  static bool _modeLoaded = false;
  bool _voiceMode = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    _voiceMode = _cachedVoiceMode;
    if (!_modeLoaded) {
      unawaited(_loadModePref());
    }
  }

  Future<void> _loadModePref() async {
    _modeLoaded = true;
    try {
      if (!AppPaths.ready) return;
      final file = File('${AppPaths.documents.path}/composer_mode.txt');
      if (await file.exists()) {
        final val = (await file.readAsString()).trim();
        final isVoice = val == 'voice';
        _cachedVoiceMode = isVoice;
        if (mounted && _voiceMode != isVoice) {
          setState(() => _voiceMode = isVoice);
        }
      }
    } catch (_) {}
  }

  void _toggleInputMode() {
    final next = !_voiceMode;
    if (next) {
      _focus.unfocus();
    } else {
      _focus.requestFocus();
    }
    setState(() => _voiceMode = next);
    _cachedVoiceMode = next;
    try {
      if (AppPaths.ready) {
        final file = File('${AppPaths.documents.path}/composer_mode.txt');
        unawaited(file.writeAsString(next ? 'voice' : 'text'));
      }
    } catch (_) {}
  }

  void _onTextChanged() => _refreshCanSubmit();

  /// 见文件头第 1 条：必须与上一次的值比，不能与「从当前输入框现算的值」比。
  void _refreshCanSubmit() {
    final has = _hasContent;
    if (has != _hadContent) setState(() => _hadContent = has);
  }

  bool get _hasContent =>
      _controller.text.trim().isNotEmpty || _photos.isNotEmpty || _files.isNotEmpty || _audio != null;

  @override
  void dispose() {
    _ticker?.cancel();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focus.dispose();
    unawaited(_recorder.dispose());
    super.dispose();
  }

  bool get _locked => widget.busy || _sending || _processingTotal > 0;
  bool get _canSubmit => _hadContent && !_locked;

  // ── 提示 ────────────────────────────────────────────────

  void _toast(String message) {
    if (!mounted) return;
    final c = FindrColors.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, style: TextStyle(fontSize: 13, color: c.text)),
          backgroundColor: c.surface,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
  }

  Future<void> _alert(String title, String body, {List<Widget> actions = const <Widget>[]}) {
    final c = FindrColors.of(context);
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: Text(title, style: TextStyle(fontSize: 16, color: c.text)),
        content: Text(body, style: TextStyle(fontSize: 13, height: 1.5, color: c.textSecondary)),
        actions: actions.isEmpty
            ? <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text('知道了', style: TextStyle(color: c.record)),
                ),
              ]
            : actions,
      ),
    );
  }

  // ── 加素材 ──────────────────────────────────────────────

  /// 把用户刚拿到的一批原图逐张压成 WebP。
  ///
  /// **一张一张来**：解码 + 缩放是 CPU 密集的，一次丢 8 张进 isolate 池
  /// 会让低端机同时开 8 个 isolate；而顺序处理还能给一个明确的「2/5」。
  Future<void> _addRawPhotos(List<RawPhoto> raws) async {
    if (raws.isEmpty) return;
    final limitHint = overImageLimitHint(_photos.length + raws.length);

    setState(() {
      _processingDone = 0;
      _processingTotal = raws.length;
      _expanded = false;
    });

    final failures = <String>[];
    for (final raw in raws) {
      final result = await compute(compressToWebp, raw.bytes);
      if (!mounted) return;
      switch (result) {
        case CompressOk(:final webp, :final width, :final height):
          _photos.add(PendingPhoto(webp: webp, width: width, height: height));
        case CompressFailed(:final reason):
          failures.add('「${raw.name}」：$reason');
      }
      setState(() => _processingDone++);
    }

    if (!mounted) return;
    setState(() {
      _processingTotal = 0;
      _processingDone = 0;
    });
    _refreshCanSubmit();

    if (failures.isNotEmpty) {
      await _alert('有 ${failures.length} 张没能加进来', failures.join('\n'));
    }
    if (limitHint != null && mounted) {
      // 需求 5.1：超过软阈值**只提示**，不做硬截断
      await _alert('图片有点多', limitHint);
    }
  }

  Future<void> _takePhoto() async {
    setState(() => _expanded = false);
    try {
      final one = await takePhoto();
      if (one != null) await _addRawPhotos(<RawPhoto>[one]);
    } on PickError catch (e) {
      await _alert('没能拍照', e.message);
    } catch (e) {
      await _alert('没能拍照', '$e');
    }
  }

  Future<void> _openLibrary() async {
    setState(() => _expanded = false);
    try {
      await _addRawPhotos(await pickPhotos());
    } on PickError catch (e) {
      await _alert('打不开相册', e.message);
    } catch (e) {
      await _alert('打不开相册', '$e');
    }
  }

  Future<void> _pickFile() async {
    setState(() => _expanded = false);
    if (_locked) return;
    final picked = await pickPlainTextFile();
    if (picked == null || !mounted) return;
    final result = await readPlainTextFile(picked);
    if (!mounted) return;
    switch (result) {
      case TextFileOk():
        setState(() => _files.add(result));
        _refreshCanSubmit();
        _toast('已读入「${result.fileName}」${result.text.length} 字，按「存」一并记下');
      case TextFileRejected(:final message):
        await _alert('没能读这个文件', message);
    }
  }

  // ── 录音 ────────────────────────────────────────────────

  Future<void> _startRecording() async {
    if (_locked || _recording || !widget.enabled) return;
    setState(() => _expanded = false);
    try {
      await _recorder.start();
      if (!mounted) return;
      setState(() => _recording = true);
      // 自己起个节拍器显示秒数。`record` 不直接给时长，用开始时刻算最可靠
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted) setState(() {});
      });
    } on RecorderError catch (e) {
      await _alert('录不了音', e.message);
    } catch (e) {
      await _alert('录不了音', '$e');
    }
  }

  Future<void> _stopRecording() async {
    if (!_recording) return;
    _ticker?.cancel();
    _ticker = null;
    final audio = await _recorder.stop();
    if (!mounted) return;
    setState(() {
      _recording = false;
      if (audio != null) _audio = audio;
    });
    _refreshCanSubmit();
    // 误触（太短 / 没拿到文件）时 `stop()` 回 null —— 什么都不做，也不打扰用户
    if (audio != null) _toast('录了 ${(audio.durationMs / 1000).toStringAsFixed(1)} 秒，按「存」记下');
  }

  // ── 提交 ────────────────────────────────────────────────

  Future<void> _submit({bool forceWithVisionOff = false}) async {
    if (_locked || !_hasContent) return;
    final text = <String>[_controller.text.trim(), ..._files.map((f) => f.text)]
        .where((s) => s.isNotEmpty)
        .join('\n\n');
    final photos = List<PendingPhoto>.of(_photos);
    final audio = _audio;
    if (photos.isEmpty && audio == null && text.isEmpty) return;

    // 关掉图片分析又没有文字：**没有任何可抽取的信息源**（需求 5.1）。
    // 这时不静默存下，先问一句 —— 纯图片卡片之后只能靠分类和标签找到它。
    if (!forceWithVisionOff && !_vision && photos.isNotEmpty && text.isEmpty) {
      final c = FindrColors.of(context);
      await _alert(
        '没有可分析的内容',
        '打开图片分析，或者补一句话。也可以存成纯图片卡片 —— 之后只能靠分类和标签找到它。',
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('继续编辑', style: TextStyle(color: c.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              unawaited(_submit(forceWithVisionOff: true));
            },
            child: Text('存为纯图片卡片', style: TextStyle(color: c.danger)),
          ),
        ],
      );
      return;
    }

    setState(() => _sending = true);
    try {
      await widget.onSubmit(
        ComposerPayload(
          text: text,
          photos: photos,
          audio: audio,
          fromFile: _files.isNotEmpty,
          vision: _vision,
          visionOverride: _visionOverride,
        ),
      );
      if (!mounted) return;
      setState(() {
        _controller.clear();
        _photos.clear();
        _files.clear();
        _audio = null;
        _visionOverride = null;
        _expanded = false;
      });
      _refreshCanSubmit();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    // 录完一条继续留着键盘 —— 连着记几笔是常态，每存一条就收一次很烦（语音模式下不弹出键盘）
    if (mounted && !_voiceMode) _focus.requestFocus();
  }

  // ── UI ─────────────────────────────────────────────────

  Future<void> _openAttachSheet() async {
    if (_locked) return;
    final c = FindrColors.of(context);
    setState(() => _expanded = true);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Spacing.four, Spacing.two, Spacing.four, Spacing.four),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
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
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '添加素材',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.text),
                    ),
                  ),
                  Text(
                    '已有内容会一起带上',
                    style: TextStyle(fontSize: 12, color: c.textMuted),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.four),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _AttachCard(
                      icon: Icons.camera_alt_rounded,
                      title: '拍照 / 连拍',
                      subtitle: '不限张数 拍完接着拍',
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        unawaited(_takePhoto());
                      },
                    ),
                  ),
                  const SizedBox(width: Spacing.two),
                  Expanded(
                    child: _AttachCard(
                      icon: Icons.photo_library_rounded,
                      title: '从相册选',
                      subtitle: '支持多选 不限张数',
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        unawaited(_openLibrary());
                      },
                    ),
                  ),
                  const SizedBox(width: Spacing.two),
                  Expanded(
                    child: _AttachCard(
                      icon: Icons.description_rounded,
                      title: '纯文本文件',
                      subtitle: 'txt / md ≤8k字',
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        unawaited(_pickFile());
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    // 面板关掉（选完 / 点外面）就恢复 ✕ → ＋
    if (mounted) setState(() => _expanded = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final hasAttachments = _photos.isNotEmpty || _files.isNotEmpty || _audio != null;

    return Container(
      decoration: BoxDecoration(
        color: c.surface,
      ),
      child: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: maxContentWidth),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.three,
                Spacing.two + 2,
                Spacing.three,
                Spacing.two + 2,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (widget.notice != null) ...<Widget>[
                    widget.notice!,
                    const SizedBox(height: Spacing.three),
                  ],
                  if (hasAttachments) ...<Widget>[
                    _AttachStrip(
                      photos: _photos,
                      files: _files,
                      audio: _audio,
                      vision: _vision,
                      visionCapable: widget.visionCapable,
                      enabled: !_locked,
                      onRemovePhoto: (i) {
                        setState(() => _photos.removeAt(i));
                        _refreshCanSubmit();
                      },
                      onRemoveFile: (i) {
                        setState(() => _files.removeAt(i));
                        _refreshCanSubmit();
                      },
                      onRemoveAudio: () {
                        setState(() => _audio = null);
                        _refreshCanSubmit();
                      },
                      onToggleVision: () {
                        setState(() => _visionOverride = !_vision);
                        // 这一步不改动「存」的可用性，但仍要重建以便开关变色
                      },
                    ),
                    const SizedBox(height: Spacing.two),
                  ],
                  if (_photos.isNotEmpty) ...<Widget>[
                    _ShootingHint(count: _photos.length, onAdd: _takePhoto, enabled: !_locked),
                    const SizedBox(height: Spacing.two),
                  ],
                  if (_photos.isNotEmpty && !_vision) ...<Widget>[
                    Text(
                      widget.visionCapable
                          ? '图片不发给模型，图里的内容不会被搜到（之后可以「补分析图片」）'
                          : '当前模型无视觉能力，图片仅作附件保存',
                      style: TextStyle(fontSize: 11, height: 1.4, color: c.textMuted),
                    ),
                    const SizedBox(height: Spacing.two),
                  ],
                  if (_processingTotal > 0) ...<Widget>[
                    _Progress(text: '正在处理图片 $_processingDone/$_processingTotal…'),
                    const SizedBox(height: Spacing.two),
                  ],
                  if (_recording) ...<Widget>[
                    _Progress(
                      text: '● 录音中 ${(_recorder.elapsedMs / 1000).round()}s · 松开结束',
                      color: c.danger,
                    ),
                    const SizedBox(height: Spacing.two),
                  ],
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      // 左1：微信式输入模式切换（话筒 / 键盘）
                      _IconBox(
                        icon: _voiceMode ? Icons.keyboard_alt_outlined : Icons.mic_none_rounded,
                        active: _voiceMode,
                        tooltip: _voiceMode ? '切换文字输入' : '切换语音输入',
                        onPressed: widget.enabled && !_locked ? _toggleInputMode : null,
                      ),
                      const SizedBox(width: Spacing.two),
                      // 中间：文字输入框（垂直居中）或「按住 说话」药丸条
                      Expanded(
                        child: !_voiceMode
                            ? Container(
                                constraints: const BoxConstraints(minHeight: 38),
                                decoration: BoxDecoration(
                                  color: c.surfaceAlt,
                                  borderRadius: BorderRadius.circular(Radii.pill),
                                ),
                                child: TextField(
                                  controller: _controller,
                                  focusNode: _focus,
                                  enabled: widget.enabled && !_locked,
                                  minLines: 1,
                                  maxLines: 4,
                                  textAlignVertical: TextAlignVertical.center,
                                  textInputAction: TextInputAction.send,
                                  // 打字回车即存（需求六）
                                  onSubmitted: (_) => unawaited(_submit()),
                                  style: TextStyle(fontSize: 14, color: c.text),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    border: InputBorder.none,
                                    hintText: widget.enabled ? '记一笔…（回车即存）' : '数据库还没就绪',
                                    hintStyle: TextStyle(fontSize: 12.5, color: c.textMuted),
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9.5),
                                  ),
                                ),
                              )
                            : _HoldToSpeakBar(
                                recording: _recording,
                                enabled: widget.enabled && !_locked,
                                onDown: _startRecording,
                                onUp: _stopRecording,
                              ),
                      ),
                      const SizedBox(width: Spacing.two),
                      // 右2：＋ 展开素材
                      _IconBox(
                        icon: _expanded ? Icons.close_rounded : Icons.add_rounded,
                        active: _expanded,
                        tooltip: '添加素材',
                        onPressed: widget.enabled && !_locked ? _openAttachSheet : null,
                      ),
                      const SizedBox(width: Spacing.two),
                      // 右1（最右侧）：存按钮（逻辑终点）
                      _SaveButton(
                        enabled: widget.enabled && _canSubmit,
                        loading: _sending,
                        onPressed: () => unawaited(_submit()),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 拍摄引导 + 计数（需求 173：**张数不限、给出构图引导、不做硬性截断**）。
///
/// RN 那边这两句话在应用内取景器的顶栏上；我们用的是系统相机，
/// 所以它们落在录入坞上 —— 拍完回来就在眼前，接着拍点右边那颗。
class _ShootingHint extends StatelessWidget {
  const _ShootingHint({required this.count, required this.onAdd, required this.enabled});

  final int count;
  final Future<void> Function() onAdd;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.three, vertical: 6),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: c.border.withValues(alpha: 0.7)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.camera_enhance_rounded, size: 15, color: c.record),
          const SizedBox(width: Spacing.two),
          Expanded(
            child: Text(
              count == 1 ? '已拍 1 张：全貌 → 局部 → 特写' : '已拍 $count 张（不限张数）',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: c.textSecondary),
            ),
          ),
          FindrButton(
            title: '再拍一张',
            variant: FindrButtonVariant.ghost,
            compact: true,
            expand: false,
            onPressed: enabled ? () => unawaited(onAdd()) : null,
          ),
        ],
      ),
    );
  }
}

/// 底部展开的素材选项卡片。
class _AttachCard extends StatelessWidget {
  const _AttachCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    return Material(
      color: c.surfaceAlt,
      borderRadius: BorderRadius.circular(Radii.lg),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.lg),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.two, vertical: Spacing.three),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.lg),
            border: Border.all(color: c.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: c.record.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 22, color: c.record),
              ),
              const SizedBox(height: Spacing.two),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.text),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, color: c.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 附件条：图片缩略图 + 文件 chip + 录音 chip + 图片分析开关。
class _AttachStrip extends StatelessWidget {
  const _AttachStrip({
    required this.photos,
    required this.files,
    required this.audio,
    required this.vision,
    required this.visionCapable,
    required this.enabled,
    required this.onRemovePhoto,
    required this.onRemoveFile,
    required this.onRemoveAudio,
    required this.onToggleVision,
  });

  final List<PendingPhoto> photos;
  final List<TextFileOk> files;
  final RecordedAudio? audio;
  final bool vision;
  final bool visionCapable;
  final bool enabled;
  final void Function(int index) onRemovePhoto;
  final void Function(int index) onRemoveFile;
  final VoidCallback onRemoveAudio;
  final VoidCallback onToggleVision;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final totalKb = photos.fold<int>(0, (sum, p) => sum + p.approxKb);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        // ⚠️ 横向列表必须 `Expanded` 包住：不写它按内容撑宽，
        // 会把右边的「图片分析」开关顶出屏幕（横向 ListView 在 Row 里的默认宽度就是内容宽度）。
        Expanded(
          child: SizedBox(
            height: 54,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: photos.length + files.length + (audio == null ? 0 : 1),
              separatorBuilder: (_, _) => const SizedBox(width: Spacing.two),
              itemBuilder: (_, i) {
                if (i < photos.length) {
                  return _ThumbTile(
                    photo: photos[i],
                    onRemove: enabled ? () => onRemovePhoto(i) : null,
                  );
                }
                final j = i - photos.length;
                if (j < files.length) {
                  final f = files[j];
                  return _ChipTile(
                    label: '📄 ${f.fileName}',
                    sub: '${f.text.length} 字',
                    onRemove: enabled ? () => onRemoveFile(j) : null,
                  );
                }
                return _ChipTile(
                  label: '🎙️ 录音',
                  sub: '${(audio!.durationMs / 1000).toStringAsFixed(1)}s',
                  onRemove: enabled ? onRemoveAudio : null,
                );
              },
            ),
          ),
        ),
        if (photos.isNotEmpty) ...<Widget>[
          const SizedBox(width: Spacing.two),
          GestureDetector(
            onTap: visionCapable && enabled ? onToggleVision : null,
            child: Container(
              decoration: BoxDecoration(
                color: vision ? c.record : c.surfaceAlt,
                borderRadius: BorderRadius.circular(Radii.pill),
                border: Border.all(color: vision ? c.record : c.border),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Text(
                '图片分析·${visionCapable ? (vision ? '开' : '关') : '不可用'}${
                  photos.length > 1 ? ' · ${photos.length}张' : ''
                }${totalKb > 0 ? ' · ${totalKb}KB' : ''}',
                style: TextStyle(
                  fontSize: 11,
                  color: vision && visionCapable ? c.recordText : c.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ThumbTile extends StatelessWidget {
  const _ThumbTile({required this.photo, this.onRemove});

  final PendingPhoto photo;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    return SizedBox(
      width: 48,
      height: 54,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            left: 0,
            bottom: 0,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.sm),
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(border: Border.all(color: c.border)),
                child: Image.memory(photo.webp, fit: BoxFit.cover, gaplessPlayback: true),
              ),
            ),
          ),
          // 删除角标是缩略图的**子元素**，不是浮层 —— 别改成全屏 absolute
          Positioned(
            top: 0,
            right: 0,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                width: 19,
                height: 19,
                decoration: BoxDecoration(color: c.danger, shape: BoxShape.circle),
                child: const Icon(Icons.close_rounded, size: 13, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChipTile extends StatelessWidget {
  const _ChipTile({required this.label, required this.sub, this.onRemove});

  final String label;
  final String sub;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: Spacing.two),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: c.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: c.textSecondary),
                ),
                Text(sub, style: TextStyle(fontSize: 10, color: c.textMuted)),
              ],
            ),
          ),
          const SizedBox(width: Spacing.one),
          GestureDetector(
            onTap: onRemove,
            child: Icon(Icons.close_rounded, size: 14, color: c.textMuted),
          ),
        ],
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.text, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 2, color: color ?? c.record),
          ),
          const SizedBox(width: Spacing.two),
          Text(text, style: TextStyle(fontSize: 11.5, color: color ?? c.textSecondary)),
        ],
      ),
    );
  }
}

/// ＋：展开加素材。**就地展开（弹一层），不跳页** —— 需求六明确要求。
class _IconBox extends StatelessWidget {
  const _IconBox({
    required this.icon,
    this.onPressed,
    this.active = false,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final bool active;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final on = onPressed != null;
    Widget button = Material(
      color: c.surfaceAlt,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.pill),
        side: BorderSide.none,
      ),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(Radii.pill),
        child: SizedBox(
          width: 38,
          height: 38,
          child: Icon(icon, size: 20, color: active ? c.record : (on ? c.textSecondary : c.textMuted)),
        ),
      ),
    );
    if (tooltip != null) {
      button = Tooltip(message: tooltip!, child: button);
    }
    return button;
  }
}

/// 「存」—— 整屏唯一用「记」的强调色实心块（需求六：与「查」强区分）。
class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.enabled, required this.loading, required this.onPressed});

  final bool enabled;
  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final active = enabled || loading;
    return Material(
      color: active ? c.record : c.surfaceAlt,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.pill),
        side: BorderSide.none,
      ),
      child: InkWell(
        onTap: enabled ? onPressed : null,
        borderRadius: BorderRadius.circular(Radii.pill),
        child: SizedBox(
          width: 44,
          height: 38,
          child: loading
              ? Center(
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: c.recordText),
                  ),
                )
              : Center(
                  child: Text(
                    '存',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: enabled ? c.recordText : c.textMuted,
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// 微信式「按住 说话」药丸条。
///
/// 用裸指针事件（Listener），与 RN 的 `onPressIn / onPressOut` 对齐：
/// 按下即开始录、松开即结束。太短的由 recorder 判为误触丢掉。
class _HoldToSpeakBar extends StatelessWidget {
  const _HoldToSpeakBar({
    required this.recording,
    required this.enabled,
    required this.onDown,
    required this.onUp,
  });

  final bool recording;
  final bool enabled;
  final Future<void> Function() onDown;
  final Future<void> Function() onUp;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    return Listener(
      onPointerDown: (_) {
        if (enabled) unawaited(onDown());
      },
      onPointerUp: (_) => unawaited(onUp()),
      onPointerCancel: (_) => unawaited(onUp()),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 38,
        decoration: BoxDecoration(
          color: recording ? c.danger : c.surfaceAlt,
          borderRadius: BorderRadius.circular(Radii.pill),
          boxShadow: recording
              ? <BoxShadow>[
                  BoxShadow(
                    color: c.danger.withValues(alpha: 0.35),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              recording ? Icons.mic_rounded : Icons.mic_none_rounded,
              size: 18,
              color: recording
                  ? Colors.white
                  : (enabled ? c.textSecondary : c.textMuted),
            ),
            const SizedBox(width: Spacing.one),
            Text(
              recording ? '松开 结束' : '按住 说话',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: recording
                    ? Colors.white
                    : (enabled ? c.textSecondary : c.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
