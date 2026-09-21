/// 长按录音 —— 对应 RN 的 `capture/recorder.ts`（59 行，基于 `expo-audio`）。
///
/// 口径与 RN 完全一致（需求 5.1）：**按下开始、松开结束、输出 m4a/AAC 不转码**
/// （技术设计二：OpenAI / Gemini / 主流 ASR 都直接吃 m4a）。
///
/// 「太短」的处理也照搬：**判为误触就丢掉，既不弹窗打扰、也不生成一张空卡** ——
/// 手指蹭一下就冒出一张「没有内容」的卡片，比什么都不发生更烦人。
library;

import 'dart:io';

import 'package:findr_core/findr_core.dart';
import 'package:record/record.dart';

import '../platform/app_paths.dart';

/// 录到的一段音频（还在临时目录里，**落库时要搬进媒体目录**）。
final class RecordedAudio {
  const RecordedAudio({required this.tempPath, required this.durationMs});

  final String tempPath;
  final int durationMs;
}

/// 录音相关的失败。消息是人话。
final class RecorderError implements Exception {
  const RecorderError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 这次录音算不算误触，该不该丢。
///
/// 拆成纯函数是为了能被测试钉住 —— 判定「误触」的条件里有 `null` 路径与时长两个来源，
/// 它们分别来自插件与本地时钟，混在异步流程里很容易看串。
bool shouldDiscardRecording({required String? path, required int durationMs}) =>
    path == null || path.isEmpty || durationMs < minRecordingMs;

/// 长按录音器。**一个 Composer 持有一个**，`dispose()` 里必须收掉。
final class LongPressRecorder {
  AudioRecorder? _rec;

  /// 录音开始时刻（本地时钟）。`record` 不直接给时长，自己记更可靠。
  int? _startedAt;

  /// 临时文件的预期路径：插件在某些机型上 `stop()` 会回 null，用它兜底。
  String? _path;

  bool _recording = false;
  bool _busy = false;

  bool get recording => _recording;

  /// 已经录了多久（毫秒）。没在录则为 0。
  int get elapsedMs {
    final started = _startedAt;
    if (started == null) return 0;
    return DateTime.now().millisecondsSinceEpoch - started;
  }

  /// 按下麦克风时调。**失败要抛 [RecorderError]**，调用方负责把那句话显示出来。
  Future<void> start() async {
    if (_recording || _busy) return;
    _busy = true;
    try {
      final rec = _rec ??= AudioRecorder();
      // 没授权时这个调用会顺带把系统弹窗带出来
      if (!await rec.hasPermission()) {
        throw const RecorderError('没有麦克风权限，无法录音。可以在系统设置里给 Findr 打开麦克风。');
      }
      final path = nextTempRecordingPath();
      await rec.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: path,
      );
      _path = path;
      _startedAt = DateTime.now().millisecondsSinceEpoch;
      _recording = true;
    } on RecorderError {
      rethrow;
    } catch (e) {
      throw RecorderError('录不了音：$e');
    } finally {
      _busy = false;
    }
  }

  /// 松开麦克风时调。
  ///
  /// 返回 `null` 表示**这次是误触**（太短或者没拿到文件），不该生成卡片 ——
  /// 临时文件会被顺手删掉，不留垃圾。
  Future<RecordedAudio?> stop() async {
    if (!_recording) return null;
    final started = _startedAt;
    _startedAt = null;
    _recording = false;

    final rec = _rec;
    String? stopped;
    if (rec != null) {
      try {
        stopped = await rec.stop();
      } catch (_) {
        // 停不下来也不能吞掉已经录到的内容：下面用 _path 兜底
        stopped = null;
      }
    }
    final path = stopped ?? _path;
    final durationMs = started == null ? 0 : DateTime.now().millisecondsSinceEpoch - started;

    if (shouldDiscardRecording(path: path, durationMs: durationMs)) {
      _deleteQuietly(path);
      return null;
    }
    return RecordedAudio(tempPath: path!, durationMs: durationMs);
  }

  /// 主动放弃这次录音（比如用户按了取消）。
  Future<void> cancel() async {
    if (!_recording) return;
    _recording = false;
    _startedAt = null;
    final rec = _rec;
    if (rec != null) {
      try {
        await rec.cancel();
      } catch (_) {
        // 取消失败无所谓，临时目录本来就允许被系统清掉
      }
    }
    _deleteQuietly(_path);
  }

  Future<void> dispose() async {
    final rec = _rec;
    _rec = null;
    _recording = false;
    _startedAt = null;
    if (rec != null) {
      try {
        await rec.dispose();
      } catch (_) {
        // 插件已释放 / 平台通道已拆时不要再往上抛
      }
    }
  }

  static void _deleteQuietly(String? path) {
    if (path == null || path.isEmpty) return;
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      // 临时目录里的东西删不掉不该阻塞用户
    }
  }
}

/// 录音临时文件路径。放在临时目录（不是文档目录）—— 它只是中转，
/// 真正落库的那一份由 [LongPressRecorder] 的调用方搬进媒体目录。
String nextTempRecordingPath() {
  final stamp = DateTime.now().microsecondsSinceEpoch;
  return '${AppPaths.temp.path}/findr-rec-$stamp.m4a';
}
