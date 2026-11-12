/// 底部录入条。
///
/// **这是「记」的唯一入口**（需求六）：打字 / 拍照 / 相册 / 文本文件 / 长按语音全在这一条里，
/// 不再有「两个按钮通到同一个页面」那种事。
///
/// 版式：底部做成一整块「坞」（圆角 + 上浮阴影），
/// 打字框与「存」不再分成两个视觉单元 —— 「记」是**一条**链路，
/// 界面上就不该长得像两个并列的功能。
///
/// 三条不容易写对的口径：
///
/// 1. **「存」的亮灭要自己记住上一次的值**（`_hadText`）——
///    写成 `if (has != _canSubmit) setState(...)` 会静默失效，因为 `_canSubmit`
///    读的就是同一个 controller，新旧值永远相等，`setState` 一次都不触发。
///    （这个 bug 被 `test/memory_stream_test.dart` 抓过。）
/// 2. 图片选中后逐张读取并在后台压缩，处理期间附件条显示占位，避免整批原图常驻内存。
/// 3. **录音按键用裸指针事件**（`Listener`），不是 `onLongPress`。
///    语义等价于「按下即录、松开即结束」：
///    太短由 [shouldDiscardRecording] 判为误触丢掉，**不弹窗、不生成空卡**。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart' show XFile;

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
    this.attachments = const <PendingFile>[],
    this.fromFile = false,
    this.vision = true,
  });

  final String text;

  /// 已经压好的图片（顺序即拍摄/选择顺序）。
  final List<PendingPhoto> photos;

  /// 录音；`null` 表示这次没有语音。
  final RecordedAudio? audio;

  /// 附件文件列表。
  final List<PendingFile> attachments;

  /// 文本来源里有没有「选文件」那一份。只影响提示文案。
  final bool fromFile;

  /// 本次录入的图片分析开关最终取值。只作用于这一次，不写回设置。
  final bool vision;
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

  /// 返回 `true` 表示已经落盘成功，此时 Composer 才清空输入。
  /// 返回 `false`（或抛异常）时**必须保留全部素材** —— 用户不能因为一次写盘失败丢掉刚录的东西。
  final Future<bool> Function(ComposerPayload payload) onSubmit;
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
  final _files = <PendingFile>[];
  RecordedAudio? _audio;

  bool _expanded = false;
  bool _recording = false;

  /// 指针是否仍按着。权限弹窗会夺走触摸流并触发 `onPointerCancel`，
  /// 靠它区分「用户松手了」与「权限弹窗还没回来」。
  bool _pressing = false;

  /// `_stopRecording` 的重入闸：自动到点与用户松手可能同时触发。
  bool _stopping = false;
  Timer? _ticker;

  /// 串行压缩链：一张压完再压下一张（同时开 N 个 isolate 会压垮低端机）。
  Future<void> _compressChain = Future<void>.value();
  bool _fallbackToastShown = false;

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
        // 写失败的 Future 必须自己接住 —— 光包 try/catch 挡不住异步异常。
        unawaited(
          file
              .writeAsString(next ? 'voice' : 'text')
              .catchError((Object _) => file),
        );
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
      _controller.text.trim().isNotEmpty ||
      _photos.isNotEmpty ||
      _files.isNotEmpty ||
      _audio != null;

  @override
  void dispose() {
    _ticker?.cancel();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focus.dispose();
    unawaited(_recorder.dispose());
    super.dispose();
  }

  bool get _locked => widget.busy || _sending;
  bool get _canSubmit => _hadContent && !_locked;

  // ── 提示 ────────────────────────────────────────────────

  void _toast(String message) {
    if (!mounted) return;
    showFindrToast(context, message);
  }

  Future<void> _alert(
    String title,
    String body, {
    List<Widget> actions = const <Widget>[],
  }) {
    if (!mounted) return Future<void>.value();
    final c = FindrColors.of(context);
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: c.text,
          ),
        ),
        content: Text(
          body,
          style: TextStyle(fontSize: 13, height: 1.5, color: c.textSecondary),
        ),
        actions: actions.isEmpty
            ? <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(
                    '知道了',
                    style: TextStyle(
                      color: c.record,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ]
            : actions,
      ),
    );
  }

  // ── 加素材 ──────────────────────────────────────────────

  Future<void> _addPhotos(List<XFile> files) async {
    if (files.isEmpty || !mounted) return;
    final limitHint = overImageLimitHint(_photos.length + files.length);
    if (limitHint != null) {
      await _alert('图片有点多', limitHint);
      if (!mounted) return;
    }

    setState(() {
      _expanded = false;
      for (final file in files) {
        final photo = PendingPhoto();
        _photos.add(photo);
        final task = _compressChain.then((_) => _compressOne(photo, file));
        // 链不能因为一张图失败而断掉；失败已经在 `_compressOne` 里降级成「原图」。
        _compressChain = task.catchError((Object _) {});
        photo.compressFuture = task;
      }
    });
    _refreshCanSubmit();
  }

  Future<void> _compressOne(PendingPhoto photo, XFile file) async {
    if (!mounted || !_photos.contains(photo)) return;
    final Uint8List source;
    try {
      source = await readPhoto(file);
    } catch (e) {
      if (mounted) {
        setState(() => _photos.remove(photo));
        _refreshCanSubmit();
        _toast('$e');
      }
      return;
    }
    if (!mounted || !_photos.contains(photo)) return;
    CompressResult result;
    try {
      result = await compute(compressToWebp, source);
    } catch (e) {
      result = CompressFailed('压缩失败：$e');
    }
    if (!mounted || !_photos.contains(photo)) return;
    switch (result) {
      case CompressOk():
        photo.setCompressed(
          webp: result.webp,
          width: result.width,
          height: result.height,
        );
      case CompressFailed(:final reason):
        // 退原图，但用真实后缀落盘。假装成 .webp 会让图片永久打不开、
        // 还会把错误 MIME 送给视觉模型。
        photo.setFallback(bytes: source, reason: reason, ext: originalImageExt(source));
        if (!_fallbackToastShown) {
          _fallbackToastShown = true;
          _toast('有图片没能压缩，已按原图保存');
        }
    }
    if (mounted) setState(() {});
  }

  Future<void> _takePhoto() async {
    setState(() => _expanded = false);
    try {
      final one = await takePhoto();
      if (one != null) await _addPhotos(<XFile>[one]);
    } on PickError catch (e) {
      await _alert('没能拍照', e.message);
    } catch (e) {
      await _alert('没能拍照', '$e');
    }
  }

  Future<void> _openLibrary() async {
    setState(() => _expanded = false);
    try {
      await _addPhotos(await pickPhotos());
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
    try {
      // 扩展名白名单 / 20000 字上限 / 编码识别都在 `text_file.dart` 里，
      // 这里必须走同一条判定 —— 自己再写一套的结果是「保存成功但搜不到」。
      final result = await readPlainTextFile(picked);
      if (!mounted) return;
      switch (result) {
        case TextFileRejected(:final message):
          await _alert('这个文件不能读', message);
        case TextFileOk(:final text, :final fileName, :final bytes):
          setState(
            () => _files.add(
              PendingFile(name: fileName, bytes: bytes, text: text),
            ),
          );
          _refreshCanSubmit();
      }
    } catch (e) {
      if (mounted) _toast('读取文件失败: $e');
    }
  }

  // ── 录音 ────────────────────────────────────────────────

  Future<void> _startRecording() async {
    if (_locked || _recording || !widget.enabled) return;
    // 在 await 之前就记住「按着」：权限弹窗会触发 onPointerCancel，
    // 松手事件可能比 start() 先回来。
    _pressing = true;
    setState(() => _expanded = false);
    try {
      await _recorder.start();
      if (!mounted) return;
      // 已经松手 / 启动被取消 ⇒ 不要进入「录音中」状态，更不要把麦克风留着
      if (!_pressing || !_recorder.recording) {
        await _recorder.cancel();
        if (mounted) setState(() => _recording = false);
        return;
      }
      setState(() => _recording = true);
      // 自己起个节拍器显示秒数。`record` 不直接给时长，用开始时刻算最可靠
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!mounted) return;
        if (shouldAutoStopRecording(_recorder.elapsedMs)) {
          _ticker?.cancel();
          _ticker = null;
          _toast('已到 1 分钟上限，录音自动结束');
          unawaited(_stopRecording());
          return;
        }
        setState(() {});
      });
    } on RecorderError catch (e) {
      _pressing = false;
      if (mounted) await _alert('录不了音', e.message);
    } catch (e) {
      _pressing = false;
      if (mounted) await _alert('录不了音', '$e');
    }
  }

  Future<void> _stopRecording() async {
    if (_stopping) return;
    _stopping = true;
    try {
      _pressing = false;
      _ticker?.cancel();
      _ticker = null;
      // 即使 `_recording` 还是 false 也要调 stop：那说明 start() 仍在等权限，
      // recorder 会把这次松手记成「启动后立刻取消」。
      final audio = await _recorder.stop();
      if (!mounted) return;
      setState(() {
        _recording = false;
        if (audio != null) _audio = audio;
      });
      _refreshCanSubmit();
    } finally {
      _stopping = false;
    }
  }

  // ── 提交 ────────────────────────────────────────────────

  Future<void> _submit() async {
    if (_locked || !_hasContent) return;

    final photos = List<PendingPhoto>.of(_photos);
    final audio = _audio;
    final userText = _controller.text.trim();
    if (photos.isEmpty && audio == null && userText.isEmpty && _files.isEmpty) {
      return;
    }

    final readableFiles = _files.where((f) => f.isReadable).toList();
    final hasPhotos = photos.isNotEmpty;
    final hasReadableFiles = readableFiles.isNotEmpty;

    // 当包含图片或可提取文本文件时，在点击「存」时唤起选项面板，明确选择是否进行 AI 分析。
    // 面板的初始值每次都是设置里的默认值（不记忆上次选择）。
    // **弹板前就置 `_sending`**：否则连点两次能叠出两层弹板。
    var vision = widget.visionDefault;
    if (hasPhotos || hasReadableFiles) {
      setState(() => _sending = true);
      final opts = await showModalBottomSheet<_SaveOptions>(
        context: context,
        backgroundColor: FindrColors.of(context).surface,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl)),
        ),
        builder: (sheetContext) => _SaveOptionsSheet(
          hasPhotos: hasPhotos,
          photoCount: photos.length,
          visionCapable: widget.visionCapable,
          initialVision: widget.visionDefault,
          hasReadableFiles: hasReadableFiles,
          readableFileCount: readableFiles.length,
          initialExtractFiles: readableFiles.any((f) => f.includeContent),
          hasOtherContent: userText.isNotEmpty || audio != null,
        ),
      );
      if (!mounted) return;
      if (opts == null) {
        setState(() => _sending = false);
        return;
      }

      vision = opts.vision;
      for (final f in _files) {
        if (f.isReadable) {
          f.includeContent = opts.extractFiles;
        }
      }
    }

    final textParts = <String>[];
    if (userText.isNotEmpty) textParts.add(userText);

    for (final f in _files) {
      if (f.isReadable && f.includeContent && f.text != null) {
        textParts.add('【文件：${f.name}】\n${f.text!}');
      } else {
        textParts.add('[附件: ${f.name}]');
      }
    }
    final text = textParts.join('\n\n');

    setState(() => _sending = true);
    try {
      // 确保所有图片的后台异步压缩已完成（失败的那张已经降级成原图）。
      for (final p in photos) {
        if (!p.isReady) await p.compressFuture;
      }
      photos.removeWhere((p) => !p.isReady);
      if (photos.isEmpty && audio == null && text.isEmpty && _files.isEmpty) {
        return;
      }

      final ok = await widget.onSubmit(
        ComposerPayload(
          text: text,
          photos: photos,
          audio: audio,
          attachments: List<PendingFile>.of(_files),
          fromFile: _files.isNotEmpty,
          vision: vision,
        ),
      );
      if (!mounted) return;
      if (!ok) {
        // 落盘失败：**内容一个都不许清**。用户看到提示后可以重试。
        _toast('没能存下，内容还在，稍后重试');
        return;
      }
      setState(() {
        _controller.clear();
        _photos.clear();
        _files.clear();
        _audio = null;
        _expanded = false;
      });
      _refreshCanSubmit();
    } catch (e) {
      if (mounted) _toast('没能存下：$e');
      return;
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
          padding: const EdgeInsets.fromLTRB(
            Spacing.four,
            Spacing.two,
            Spacing.four,
            Spacing.four,
          ),
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
              Text(
                '添加素材',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: c.text,
                ),
              ),
              const SizedBox(height: Spacing.four),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _AttachCard(
                      icon: Icons.camera_alt_rounded,
                      title: '拍照',
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
                      title: '图片',
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        unawaited(_openLibrary());
                      },
                    ),
                  ),
                  const SizedBox(width: Spacing.two),
                  Expanded(
                    child: _AttachCard(
                      icon: Icons.attach_file_rounded,
                      title: '添加文件',
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
    final hasAttachments =
        _photos.isNotEmpty || _files.isNotEmpty || _audio != null;

    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: c.shadow.withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
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
                    ),
                    const SizedBox(height: Spacing.two),
                  ],
                  if (_recording) ...<Widget>[
                    _Progress(
                      text:
                          '● 录音中 ${(_recorder.elapsedMs / 1000).round()}s · 松开结束',
                      color: c.danger,
                    ),
                    const SizedBox(height: Spacing.two),
                  ],
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      // 左1：微信式输入模式切换（话筒 / 键盘）
                      _IconBox(
                        icon: _voiceMode
                            ? Icons.keyboard_alt_outlined
                            : Icons.mic_none_rounded,
                        active: _voiceMode,
                        tooltip: _voiceMode ? '切换文字输入' : '切换语音输入',
                        onPressed: widget.enabled && !_locked
                            ? _toggleInputMode
                            : null,
                      ),
                      const SizedBox(width: Spacing.two),
                      // 中间：文字输入框（垂直居中）或「按住 说话」药丸条
                      Expanded(
                        child: !_voiceMode
                            ? Container(
                                constraints: const BoxConstraints(
                                  minHeight: 38,
                                ),
                                decoration: BoxDecoration(
                                  color: c.surfaceAlt,
                                  borderRadius: BorderRadius.circular(
                                    Radii.pill,
                                  ),
                                ),
                                child: TextField(
                                  controller: _controller,
                                  focusNode: _focus,
                                  enabled: widget.enabled,
                                  // 提交期间只读，不要 disabled：disabled 会丢焦点、
                                  // 收键盘，保存后再 requestFocus 就会闪一下。
                                  readOnly: _locked,
                                  minLines: 1,
                                  maxLines: 4,
                                  textAlignVertical: TextAlignVertical.center,
                                  textInputAction: TextInputAction.send,
                                  // 默认行为会在 send 后 unfocus（收键盘），这里用空回调
                                  // 覆盖掉；焦点保留，键盘就不会先关再开。
                                  onEditingComplete: () {},
                                  // 打字回车即存（需求六）
                                  onSubmitted: (_) => unawaited(_submit()),
                                  style: TextStyle(fontSize: 14, color: c.text),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    border: InputBorder.none,
                                    hintText: widget.enabled
                                        ? '记一笔…（回车即存）'
                                        : '数据库还没就绪',
                                    hintStyle: TextStyle(
                                      fontSize: 12.5,
                                      color: c.textMuted,
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 9.5,
                                    ),
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
                        icon: _expanded
                            ? Icons.close_rounded
                            : Icons.add_rounded,
                        active: _expanded,
                        tooltip: '添加素材',
                        onPressed: widget.enabled && !_locked
                            ? _openAttachSheet
                            : null,
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

/// 底部展开的素材选项卡片。
class _AttachCard extends StatelessWidget {
  const _AttachCard({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
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
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.two,
            vertical: Spacing.three,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.lg),
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
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: c.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 附件条：统一药丸条，横向滚动的图片、文件与录音。
class _AttachStrip extends StatelessWidget {
  const _AttachStrip({
    required this.photos,
    required this.files,
    required this.audio,
    required this.enabled,
    required this.onRemovePhoto,
    required this.onRemoveFile,
    required this.onRemoveAudio,
  });

  final List<PendingPhoto> photos;
  final List<PendingFile> files;
  final RecordedAudio? audio;
  final bool enabled;
  final void Function(int index) onRemovePhoto;
  final void Function(int index) onRemoveFile;
  final VoidCallback onRemoveAudio;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: photos.length + files.length + (audio == null ? 0 : 1),
        separatorBuilder: (_, _) => const SizedBox(width: Spacing.two),
        itemBuilder: (context, i) {
          final c = FindrColors.of(context);
          if (i < photos.length) {
            final p = photos[i];
            return _AttachTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.pill),
                child: !p.isReady
                    ? SizedBox(
                        width: 24,
                        height: 24,
                        child: Padding(
                          padding: const EdgeInsets.all(5),
                          child: CircularProgressIndicator(strokeWidth: 1.5, color: c.textMuted),
                        ),
                      )
                    : Image.memory(
                        p.thumbBytes,
                        cacheWidth: 64,
                        cacheHeight: 64,
                        width: 24,
                        height: 24,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) =>
                            Icon(Icons.image_outlined, size: 24, color: c.textMuted),
                      ),
              ),
              label: p.isFallback
                  ? '图片 ${i + 1}（原图）'
                  : (photos.length > 1 ? '图片 ${i + 1}' : '图片'),
              sizeText: p.approxKb > 0 ? '${p.approxKb}KB' : null,
              onRemove: enabled ? () => onRemovePhoto(i) : null,
            );
          }
          final j = i - photos.length;
          if (j < files.length) {
            final f = files[j];
            return _AttachTile(
              leading: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: c.textSecondary.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  f.isReadable
                      ? Icons.description_outlined
                      : Icons.attach_file_rounded,
                  size: 13,
                  color: c.textSecondary,
                ),
              ),
              label: f.name,
              sizeText: '${f.sizeKb}KB',
              onRemove: enabled ? () => onRemoveFile(j) : null,
            );
          }
          return _AttachTile(
            leading: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: c.record.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.mic_none_rounded, size: 13, color: c.record),
            ),
            label: '语音',
            sizeText: '${(audio!.durationMs / 1000).toStringAsFixed(1)}s',
            onRemove: enabled ? onRemoveAudio : null,
          );
        },
      ),
    );
  }
}

/// 统一规格的附件 Pill 组件（34px 高）
class _AttachTile extends StatelessWidget {
  const _AttachTile({
    this.leading,
    required this.label,
    this.sizeText,
    this.onRemove,
  });

  final Widget? leading;
  final String label;
  final String? sizeText;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (leading != null) ...<Widget>[leading!, const SizedBox(width: 6)],
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 110),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: c.text,
              ),
            ),
          ),
          if (sizeText != null) ...<Widget>[
            const SizedBox(width: 5),
            Text(sizeText!, style: TextStyle(fontSize: 11, color: c.textMuted)),
          ],
          if (onRemove != null) ...<Widget>[
            const SizedBox(width: 6),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onRemove,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.close_rounded, size: 14, color: c.textMuted),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SaveOptions {
  const _SaveOptions({required this.vision, required this.extractFiles});

  final bool vision;
  final bool extractFiles;
}

/// 存入时的选项底板：针对图片与文本文件，明确询问是否进行 AI 提取与解析
class _SaveOptionsSheet extends StatefulWidget {
  const _SaveOptionsSheet({
    required this.hasPhotos,
    required this.photoCount,
    required this.visionCapable,
    required this.initialVision,
    required this.hasReadableFiles,
    required this.readableFileCount,
    required this.initialExtractFiles,
    required this.hasOtherContent,
  });

  final bool hasPhotos;
  final int photoCount;
  final bool visionCapable;
  final bool initialVision;
  final bool hasReadableFiles;
  final int readableFileCount;
  final bool initialExtractFiles;
  final bool hasOtherContent;

  @override
  State<_SaveOptionsSheet> createState() => _SaveOptionsSheetState();
}

class _SaveOptionsSheetState extends State<_SaveOptionsSheet> {
  late bool _vision;
  late bool _extractFiles;

  @override
  void initState() {
    super.initState();
    _vision = widget.visionCapable && widget.initialVision;
    _extractFiles = widget.initialExtractFiles;
  }

  @override
  Widget build(BuildContext context) {
    final c = FindrColors.of(context);
    final isPureAttachmentOnly =
        !widget.hasOtherContent &&
        (!widget.hasPhotos || !_vision) &&
        (!widget.hasReadableFiles || !_extractFiles);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Spacing.four,
          Spacing.two,
          Spacing.four,
          Spacing.four,
        ),
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
              '存入选项',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: c.text,
              ),
            ),
            const SizedBox(height: Spacing.three),
            if (widget.hasPhotos) ...<Widget>[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.three,
                  vertical: Spacing.two,
                ),
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(Radii.lg),
                ),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: c.record.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.auto_awesome_rounded,
                        size: 20,
                        color: c.record,
                      ),
                    ),
                    const SizedBox(width: Spacing.three),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'AI 识别图片内容 (${widget.photoCount}张)',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: c.text,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            !widget.visionCapable
                                ? '模型不支持视觉分析，将作为附件保存'
                                : (_vision ? '模型分析图中物品并提取记忆' : '仅存为图片，不发给模型'),
                            style: TextStyle(
                              fontSize: 12,
                              color: !widget.visionCapable
                                  ? c.textMuted
                                  : c.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: Spacing.two),
                    Switch.adaptive(
                      value: widget.visionCapable && _vision,
                      onChanged: widget.visionCapable
                          ? (val) => setState(() => _vision = val)
                          : null,
                      activeTrackColor: c.record,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Spacing.two),
            ],
            if (widget.hasReadableFiles) ...<Widget>[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.three,
                  vertical: Spacing.two,
                ),
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(Radii.lg),
                ),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: c.record.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.description_rounded,
                        size: 20,
                        color: c.record,
                      ),
                    ),
                    const SizedBox(width: Spacing.three),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '提取文本文件内容 (${widget.readableFileCount}个)',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: c.text,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _extractFiles ? '文字追加到正文，可被搜到' : '只存附件，不解析正文',
                            style: TextStyle(
                              fontSize: 12,
                              color: c.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: Spacing.two),
                    Switch.adaptive(
                      value: _extractFiles,
                      onChanged: (val) => setState(() => _extractFiles = val),
                      activeTrackColor: c.record,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Spacing.two),
            ],
            if (isPureAttachmentOnly) ...<Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text(
                  '没文字又不做分析，只能靠分类和标签找。',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.4,
                    color: c.danger,
                  ),
                ),
              ),
              const SizedBox(height: Spacing.two),
            ],
            const SizedBox(height: Spacing.two),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: c.border),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Radii.pill),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: Text(
                      '取消',
                      style: TextStyle(color: c.textSecondary, fontSize: 14),
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.three),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).pop(
                        _SaveOptions(
                          vision: _vision,
                          extractFiles: _extractFiles,
                        ),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: c.record,
                      foregroundColor: c.recordText,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Radii.pill),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      elevation: 0,
                    ),
                    child: Text(
                      isPureAttachmentOnly ? '仍作为纯附件存入' : '确认存入',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
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
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: color ?? c.record,
            ),
          ),
          const SizedBox(width: Spacing.two),
          Text(
            text,
            style: TextStyle(fontSize: 11.5, color: color ?? c.textSecondary),
          ),
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
          child: Icon(
            icon,
            size: 20,
            color: active ? c.record : (on ? c.textSecondary : c.textMuted),
          ),
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
  const _SaveButton({
    required this.enabled,
    required this.loading,
    required this.onPressed,
  });

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
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: c.recordText,
                    ),
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
/// 用裸指针事件（Listener）：按下即开始录、松开即结束。太短的由 recorder 判为误触丢掉。
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
