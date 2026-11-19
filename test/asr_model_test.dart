import 'dart:io';

import 'package:findr_app/platform/app_paths.dart';
import 'package:findr_app/platform/asr_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('findr_asr_model_');
    AppPaths.initWith(root);
  });

  tearDown(() {
    AppPaths.resetForTest();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 按清单里的字节数造出占位文件（内容不重要 —— 这里只验「在不在」）。
  /// 用 `setPosition` 撑长度，别真去分配 228 MB。
  Future<void> fakeModel({int modelExtra = 0}) async {
    final dir = Directory(AppPaths.abs(asrModelDirRel))..createSync(recursive: true);
    for (final f in asrModelFiles) {
      final extra = f.name == 'model.int8.onnx' ? modelExtra : 0;
      final raf = await File('${dir.path}/${f.name}').open(mode: FileMode.write);
      await raf.setPosition(f.bytes + extra - 1);
      await raf.writeByte(0);
      await raf.close();
    }
  }

  test('总字节数是清单之和', () {
    expect(asrModelTotalBytes, 239233841 + 315894);
  });

  test('没下过就是没装', () {
    expect(asrModelPaths(), isNull);
    expect(asrModelInstalled(), isFalse);
  });

  test('少了任何一个文件都算没装', () async {
    await fakeModel();
    File('${AppPaths.abs(asrModelDirRel)}/tokens.txt').deleteSync();
    expect(asrModelInstalled(), isFalse);
  });

  test('字节数不对算没装（截断的模型会在 onnxruntime 里崩）', () async {
    await fakeModel(modelExtra: 1);
    expect(asrModelInstalled(), isFalse);
  });

  test('装好时给出两个文件的绝对路径', () async {
    await fakeModel();
    expect(asrModelInstalled(), isTrue);
    final paths = asrModelPaths()!;
    expect(paths.model, AppPaths.abs('$asrModelDirRel/model.int8.onnx'));
    expect(paths.tokens, AppPaths.abs('$asrModelDirRel/tokens.txt'));
    expect(File(paths.model).existsSync(), isTrue);
  });

  test('删除把整个目录带走', () async {
    await fakeModel();
    removeAsrModel();
    expect(asrModelInstalled(), isFalse);
    expect(Directory(AppPaths.abs(asrModelDirRel)).existsSync(), isFalse);
  });
}
