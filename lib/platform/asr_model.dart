/// 本机转写模型的清单、落点与下载。
///
/// 模型不进安装包（228 MB，比整个 APK 大），第一次要用的时侯由用户在设置页点一下下载。
/// 下载复用 `update.dart` 那套断点续传 —— 网断了不用从零开始，而 sha256 校验是必须的：
/// 截断的 ONNX 不会报错，只会让 onnxruntime 在里面崩掉，排查成本极高。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';

import 'app_paths.dart';
import 'update.dart';

/// 模型目录：`files/models/sensevoice/`。
///
/// 不能放 `files/audio` 或 `files/cards` —— 那两个是「卡片数据」，会进备份包、
/// 也会被孤儿回收扫到。模型两样都不该沾。
const String asrModelDirRel = 'files/models/sensevoice';

String get _modelDir => AppPaths.abs(asrModelDirRel);

/// 一个要下的文件。**字节数与 sha256 都是钉死的** —— 上游换了文件，这里必须跟着改，
/// 否则用户下到的是「另一个模型」，而校验会把它当失败挡住（这是对的行为）。
final class AsrModelFile {
  const AsrModelFile({
    required this.name,
    required this.bytes,
    required this.sha256,
  });

  final String name;
  final int bytes;
  final String sha256;
}

/// 上游固定在某个 commit 上：HuggingFace 的 `main` 会漂移，而 sha256 是死的。
const String _repo =
    'csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17';
const String _revision = '2365baeacb507f821a0c8120fcee3d484dba7a07';

const List<AsrModelFile> asrModelFiles = [
  AsrModelFile(
    name: 'model.int8.onnx',
    bytes: 239233841,
    sha256: 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51',
  ),
  AsrModelFile(
    name: 'tokens.txt',
    bytes: 315894,
    sha256: 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc',
  ),
];

int get asrModelTotalBytes => asrModelFiles.fold(0, (sum, f) => sum + f.bytes);

/// 模型装好的话给出两个文件路径，否则 `null`。
///
/// **只比字节数，不算 sha256**：这个判断会在每次快照 / 每次画角标时跑，
/// 而 228 MB 的哈希是秒级的。真正的校验放在下载完成那一刻（[downloadAsrModel]）。
({String model, String tokens})? asrModelPaths() {
  if (!AppPaths.ready) return null;
  for (final f in asrModelFiles) {
    final file = File('$_modelDir/${f.name}');
    if (!file.existsSync() || file.lengthSync() != f.bytes) return null;
  }
  return (model: '$_modelDir/model.int8.onnx', tokens: '$_modelDir/tokens.txt');
}

bool asrModelInstalled() => asrModelPaths() != null;

/// 下载并校验整套模型。已装好时直接返回成功（不重下）。
///
/// 镜像在前、官方在后：两家都通，镜像少一次首跳，出响应头更快；官方留作兜底。
/// **404 不换源** —— 那是「这个文件就没有」，换源也一样，只会让人多等一轮。
Future<DownloadOutcome> downloadAsrModel({
  UpdateDownloadProgress? onProgress,
  DownloadCancelToken? cancel,
}) async {
  if (asrModelInstalled()) {
    return DownloadDone(File('$_modelDir/model.int8.onnx'), asrModelTotalBytes);
  }
  final dir = Directory(_modelDir);
  if (!dir.existsSync()) dir.createSync(recursive: true);

  final total = asrModelTotalBytes;
  var done = 0;
  for (final f in asrModelFiles) {
    final target = File('${dir.path}/${f.name}');
    final base = done;
    DownloadOutcome? outcome;
    for (final host in const [
      'https://hf-mirror.com',
      'https://huggingface.co',
    ]) {
      outcome = await downloadToFile(
        url: '$host/$_repo/resolve/$_revision/${f.name}',
        target: target,
        cancel: cancel,
        onProgress: onProgress == null
            ? null
            : (received, _) => onProgress(base + received, total),
        validate: (part) async =>
            part.lengthSync() == f.bytes && await _sha256Of(part) == f.sha256,
        invalidReason: '${f.name} 校验不通过（下载到的文件不完整）',
      );
      if (outcome is DownloadDone) break;
      // 取消就是不要了，换个源重下没有意义
      if (outcome is DownloadCancelled || cancel?.isCancelled == true) {
        return outcome;
      }
    }
    if (outcome is! DownloadDone) {
      // `.part` 留着：228 MB 断在半路，重试还要从零开始就太亏了
      return DownloadFailed(
        outcome is DownloadFailed ? '模型下载失败：${outcome.reason}' : '模型下载失败',
      );
    }
    done += f.bytes;
    onProgress?.call(done, total);
  }
  return DownloadDone(File('${dir.path}/model.int8.onnx'), total);
}

/// 删掉整套模型，把空间还回去。
void removeAsrModel() {
  final dir = Directory(_modelDir);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
}

Future<String> _sha256Of(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}
