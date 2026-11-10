/// 删卡必须把媒体真正删掉。
///
/// 之前 `deleteCard` 只删 DB 行，弹窗却写着「图片和录音会一起删掉」；
/// 附件更糟：它不进 DB（详情页按目录扫描），文件会一直留着，
/// 还会被下一次备份按目录带走。这里把「删文件」这一半也钉住。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:findr_app/capture/recorder.dart';
import 'package:findr_app/capture/submit.dart';
import 'package:findr_app/platform/app_paths.dart';
import 'package:findr_app/platform/db.dart';
import 'package:findr_app/platform/media.dart';
import 'package:findr_core/findr_core.dart';
import 'package:flutter_test/flutter_test.dart';

late Directory _root;

void main() {
  setUp(() async {
    _root = await Directory.systemTemp.createTemp('findr_delete_');
    AppPaths.initWith(_root);
  });

  tearDown(() {
    AppPaths.resetForTest();
    try {
      if (_root.existsSync()) _root.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上偶尔要等句柄释放
    }
  });

  test('删卡回收：图片、录音、整个附件目录都不留', () async {
    final db = openAndMigrateDb();
    final at = DateTime(2026, 9, 22, 10, 30);

    final audioTemp = File('${AppPaths.temp.path}/rec.m4a')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(<int>[1, 2, 3], flush: true);

    final card = await persistCapture(
      db,
      CaptureSubmission(
        photos: <PendingPhoto>[
          PendingPhoto(webp: Uint8List.fromList(<int>[7, 7, 7])),
        ],
        audio: RecordedAudio(tempPath: audioTemp.path, durationMs: 1500),
      ),
      now: at,
    );

    // 附件不在 DB 里，按目录扫描展示；删卡时要靠整目录回收
    final attachDir = Directory(
      AppPaths.abs('files/cards/202609/${card.id}/attachments'),
    )..createSync(recursive: true);
    final attach = File('${attachDir.path}/清单.txt')
      ..writeAsBytesSync(<int>[9, 9], flush: true);

    final imageFile = AppPaths.file(card.images!.single);
    final audioFile = AppPaths.file(card.audioPath!);
    expect(imageFile.existsSync(), isTrue);
    expect(audioFile.existsSync(), isTrue);
    expect(attach.existsSync(), isTrue);

    // 与详情页删除顺序一致：先删行，再清图片目录与录音
    deleteCard(db, card.id);
    removeCardFiles(card);
    db.close();

    expect(imageFile.existsSync(), isFalse, reason: '图片还在 ⇒ 删除弹窗在说谎');
    expect(audioFile.existsSync(), isFalse);
    expect(attachDir.existsSync(), isFalse, reason: '附件目录必须整棵删掉');
  });
}
