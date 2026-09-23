/// 落盘 + 插行那一层的验收网。
///
/// 钉住三件**顺序与去留**上的事（它们都不会报错，只会悄悄错）：
///
/// 1. **先写文件、再插行** —— 卡片行存在时，它引用的媒体一定已经在盘上；
/// 2. **来源由手里真有什么决定** —— 图 > 音 > 文，与用户从哪个入口进来无关；
/// 3. **录音搬完就把临时文件删掉** —— 不然每录一次都在临时目录留一份残余。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:findr_app/capture/recorder.dart';
import 'package:findr_app/capture/submit.dart';
import 'package:findr_app/platform/app_paths.dart';
import 'package:findr_app/platform/db.dart';
import 'package:findr_core/findr_core.dart';
import 'package:flutter_test/flutter_test.dart';

late Directory _root;

PendingPhoto _photo(int n) => PendingPhoto(
  webp: Uint8List.fromList(List<int>.filled(n, 0x41)),
  width: 1600,
  height: 1200,
);

void main() {
  setUp(() async {
    _root = await Directory.systemTemp.createTemp('findr_submit_');
    AppPaths.initWith(_root);
  });

  tearDown(() {
    AppPaths.resetForTest();
    try {
      if (_root.existsSync()) _root.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上偶尔要等句柄释放，删不掉不影响结论
    }
  });

  group('来源判定（图 > 音 > 文）', () {
    test('只有文字 → text，且没有媒体文件被写出来', () async {
      final db = openAndMigrateDb();
      final card = await persistCapture(db, const CaptureSubmission(text: '护照放在主卧抽屉'));
      db.close();

      expect(card.source, SourceKind.text);
      expect(card.transcript, '护照放在主卧抽屉');
      expect(card.images, isNull);
      expect(card.audioPath, isNull);
    });

    test('文字**只有空白**时不落成字符串', () async {
      final db = openAndMigrateDb();
      final card = await persistCapture(db, const CaptureSubmission(text: '   \n  '));
      db.close();

      expect(card.transcript, isNull);
      expect(card.source, SourceKind.text);
    });

    test('有图 → photo（哪怕还带着文字与录音）', () async {
      final db = openAndMigrateDb();
      final audioPath = _writeTempAudio(1000);
      final card = await persistCapture(
        db,
        CaptureSubmission(
          text: '衣柜顶上',
          photos: <PendingPhoto>[_photo(8), _photo(9)],
          audio: RecordedAudio(tempPath: audioPath, durationMs: 2000),
        ),
      );
      db.close();

      expect(card.source, SourceKind.photo);
      expect(card.transcript, '衣柜顶上');
      expect(card.audioPath, isNotNull);
      expect(card.images!.length, 2);
    });

    test('只有录音 → voice', () async {
      final db = openAndMigrateDb();
      final card = await persistCapture(
        db,
        CaptureSubmission(audio: RecordedAudio(tempPath: _writeTempAudio(4), durationMs: 3000)),
      );
      db.close();

      expect(card.source, SourceKind.voice);
      expect(card.audioPath, isNotNull);
      expect(card.images, isNull);
    });
  });

  group('文件真的落到了 core 算出来的相对路径上', () {
    test('图片按顺序落成 01 / 02，卡片里存的是相对路径', () async {
      final db = openAndMigrateDb();
      final now = DateTime(2026, 9, 22, 10, 30);
      final card = await persistCapture(
        db,
        CaptureSubmission(photos: <PendingPhoto>[_photo(8), _photo(9)]),
        now: now,
      );
      db.close();

      expect(card.images, <String>[
        'files/cards/202609/${card.id}/01.webp',
        'files/cards/202609/${card.id}/02.webp',
      ]);
      for (final rel in card.images!) {
        final f = AppPaths.file(rel);
        expect(f.existsSync(), isTrue, reason: '卡片引用了 $rel，但盘上没有这个文件');
        expect((rel.split('/').last), matches(RegExp(r'^0\d\.webp$')));
      }
      // 字节原样落盘（落盘这一层不负责压缩，压缩在选图那一刻就做完了）
      expect(AppPaths.file(card.images!.first).readAsBytesSync().length, 8);
      expect(AppPaths.file(card.images!.last).readAsBytesSync().length, 9);
    });

    test('录音从临时目录搬进媒体目录，**临时文件随后被删掉**', () async {
      final db = openAndMigrateDb();
      final temp = _writeTempAudio(64);
      final card = await persistCapture(
        db,
        CaptureSubmission(audio: RecordedAudio(tempPath: temp, durationMs: 1500)),
        now: DateTime(2026, 9, 22, 10, 30),
      );
      db.close();

      expect(card.audioPath, 'files/audio/202609/${card.id}.m4a');
      expect(AppPaths.file(card.audioPath!).existsSync(), isTrue);
      expect(AppPaths.file(card.audioPath!).readAsBytesSync().length, 64);
      expect(File(temp).existsSync(), isFalse, reason: '临时文件没删掉 ⇒ 每录一次留一份残余');
    });

    test('卡片真的进了库（不只是返回了个对象）', () async {
      final db = openAndMigrateDb();
      final card = await persistCapture(db, const CaptureSubmission(text: '备用钥匙在书柜第三层'));
      final again = getCard(db, card.id);
      db.close();

      expect(again, isNotNull);
      expect(again!.transcript, '备用钥匙在书柜第三层');
    });
  });

  group('超量只提示、不截断（需求 5.1）', () {
    test('刚好到阈值不提示', () {
      expect(overImageLimitHint(maxCaptureImagesWarn), isNull);
      expect(overImageLimitHint(1), isNull);
    });

    test('超一张就提示，并且把张数与阈值都写出来', () {
      final hint = overImageLimitHint(maxCaptureImagesWarn + 1);
      expect(hint, isNotNull);
      expect(hint, contains('${maxCaptureImagesWarn + 1}'));
      expect(hint, contains('$maxCaptureImagesWarn'));
    });

    test('超很多张也只给一句提示，**不截断** —— 13 张照样全落盘', () async {
      final db = openAndMigrateDb();
      final photos = <PendingPhoto>[for (var i = 0; i < maxCaptureImagesWarn + 1; i++) _photo(4)];
      final card = await persistCapture(db, CaptureSubmission(photos: photos));
      db.close();

      expect(card.images!.length, maxCaptureImagesWarn + 1);
      for (final rel in card.images!) {
        expect(AppPaths.file(rel).existsSync(), isTrue);
      }
    });
  });

  group('误触录音的判定', () {
    test('没有路径 ⇒ 丢掉', () {
      expect(shouldDiscardRecording(path: null, durationMs: 5000), isTrue);
      expect(shouldDiscardRecording(path: '', durationMs: 5000), isTrue);
    });

    test('太短 ⇒ 丢掉（按下就松开）', () {
      expect(shouldDiscardRecording(path: '/tmp/a.m4a', durationMs: minRecordingMs - 1), isTrue);
    });

    test('刚好到下限就留', () {
      expect(shouldDiscardRecording(path: '/tmp/a.m4a', durationMs: minRecordingMs), isFalse);
      expect(shouldDiscardRecording(path: '/tmp/a.m4a', durationMs: 8000), isFalse);
    });

    test('临时录音路径落在**临时目录**里、且带 .m4a 后缀', () {
      final p = nextTempRecordingPath();
      expect(p, startsWith('${AppPaths.temp.path}/'));
      expect(p, endsWith('.m4a'));
      // 注意：`AppPaths.initWith`（测试用）刻意把 temp 摆在根目录下的 `.cache`，
      // 所以这里**不能**断言「不在 documents 下面」——真机上两者本来就是两棵树
      // （`getTemporaryDirectory()` vs `getApplicationDocumentsDirectory()`）。
      // 真正有意义的是「走的是 temp 而不是 documents」这个事实。
      expect(p, isNot(startsWith('${AppPaths.documents.path}/files/')));
    });
  });
}

String _writeTempAudio(int bytes) {
  final f = File('${AppPaths.temp.path}/rec-${DateTime.now().microsecondsSinceEpoch}.m4a');
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(List<int>.filled(bytes, 0x7A), flush: true);
  return f.path;
}
