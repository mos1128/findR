/// 本机转写：SenseVoice-small（int8 ONNX）跑在 sherpa-onnx 上。
///
/// **为什么要一个常驻 isolate**：模型 228 MB，载入一次两秒多，而推理是阻塞的
/// （FFI 一进去就不回 Dart）。放主 isolate 上界面会僵住两秒；每次调用起一个新 isolate
/// 又要把这两秒重新付一遍。所以：一个长命 worker 养着唯一一个识别器，主 isolate
/// 只负责「送采样 → 等文字」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:findr_core/findr_core.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'app_paths.dart';
import 'asr_audio.dart';
import 'asr_model.dart';
import 'pcm.dart';

/// 收敛成 core 的适配器形态 —— 队列、单卡重转、语音输入都不必分云端本机。
final class LocalAsrAdapter implements AsrProviderAdapter {
  const LocalAsrAdapter();

  @override
  Future<TranscribeResult> transcribe(
    TranscribeRequest request,
    ProviderConfig config,
  ) async {
    return TranscribeResult(
      await LocalAsr.instance.transcribe(await _samplesOf(request.audio)),
    );
  }
}

/// 两种引用都收：沙盒相对路径直接解，base64 落成临时文件再解
/// （`transcribeOnce` 与设置页探测手里都是 base64）。
Future<Float32List> _samplesOf(AudioRef audio) async {
  switch (audio) {
    case AudioFileRef(:final rel):
      return speechSamplesFromFile(AppPaths.abs(rel));
    case AudioBase64Ref(:final base64):
      final dir = await Directory.systemTemp.createTemp('findr-asr');
      try {
        final file = File('${dir.path}/audio.m4a');
        await file.writeAsBytes(base64Decode(base64), flush: true);
        return await speechSamplesFromFile(file.path);
      } finally {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {
          // 临时目录删不掉不影响结果
        }
      }
  }
}

/// 唯一的本机识别器。整个 App 共用一个 worker。
final class LocalAsr {
  LocalAsr._();

  static final LocalAsr instance = LocalAsr._();

  final ReceivePort _inbox = ReceivePort();
  bool _listening = false;
  SendPort? _to;
  Completer<SendPort>? _starting;
  Completer<String>? _pending;

  /// 一次只跑一句：调用方（解析队列、语音输入）本来就是串行的，
  /// 串行让「这个回包是谁的」不必再编一套 id。
  Future<void> _serial = Future<void>.value();

  /// worker 活着（模型已载入，后面的调用不必再等两秒）。界面据此说「已就绪」。
  bool get ready => _to != null;

  Future<String> transcribe(Float32List samples) {
    final run = _serial.then((_) => _send(samples));
    _serial = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<String> _send(Float32List samples) async {
    final port = await _ensureWorker();
    final reply = Completer<String>();
    _pending = reply;
    port.send(samples);
    return reply.future;
  }

  Future<SendPort> _ensureWorker() {
    final live = _to;
    if (live != null) return Future<SendPort>.value(live);
    final starting = _starting;
    if (starting != null) return starting.future;

    final paths = asrModelPaths();
    if (paths == null) return Future<SendPort>.error(StateError('模型尚未下载'));

    final ready = Completer<SendPort>();
    _starting = ready;
    if (!_listening) {
      _listening = true;
      _inbox.listen(_onMessage);
    }
    Isolate.spawn(
      _workerMain,
      <Object?>[_inbox.sendPort, paths.model, paths.tokens],
      onError: _inbox.sendPort,
      onExit: _inbox.sendPort,
    );
    return ready.future;
  }

  void _onMessage(Object? message) {
    if (message is SendPort) {
      _to = message;
      final starting = _starting;
      _starting = null;
      starting?.complete(message);
      return;
    }
    if (message is String) {
      final pending = _pending;
      _pending = null;
      pending?.complete(message);
      return;
    }
    if (message is _AsrFailure) {
      _fail(message.reason);
      return;
    }
    // 空 = worker 自己退了；List = isolate 未捕获的异常（[错误描述, 栈]）
    _fail(message is List ? '${message.first}' : '本机识别进程已退出');
  }

  /// 进程没了：在等的那一句与还在等的启动都判失败，并让下次调用重新拉一个。
  void _fail(String reason) {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError(reason));
    }
    final starting = _starting;
    _starting = null;
    if (starting != null && !starting.isCompleted) {
      starting.completeError(StateError(reason));
    }
    _to = null;
  }
}

/// worker 本体。**每个碰 sherpa 的 isolate 都要自己 initBindings 一次**
/// （绑定是 isolate 内的全局量）。
void _workerMain(List<Object?> init) {
  final toMain = init[0] as SendPort;
  final inbox = ReceivePort();
  toMain.send(inbox.sendPort);

  sherpa.initBindings();
  final recognizer = sherpa.OfflineRecognizer(
    sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        senseVoice: sherpa.OfflineSenseVoiceModelConfig(
          model: init[1] as String,
          // 中文笔记里夹英文是常态，交给模型自己判，不钉死 'zh'
          language: 'auto',
          useInverseTextNormalization: true,
        ),
        tokens: init[2] as String,
        numThreads: 2,
        debug: false,
      ),
    ),
  );

  inbox.listen((message) {
    if (message is! Float32List) return;
    final stream = recognizer.createStream();
    try {
      stream.acceptWaveform(samples: message, sampleRate: speechSampleRate);
      recognizer.decode(stream);
      toMain.send(_stripMarkers(recognizer.getResult(stream).text));
    } catch (e) {
      toMain.send(_AsrFailure('$e'));
    } finally {
      stream.free();
    }
  });
}

final RegExp _marker = RegExp(r'<\|[^|]*\|>');

/// 结果里偶尔会混进 `<|zh|>` 这类控制标记 —— 它们是给上层解析用的，不该显示给人。
String _stripMarkers(String text) => text.replaceAll(_marker, '').trim();

final class _AsrFailure {
  const _AsrFailure(this.reason);

  final String reason;
}
