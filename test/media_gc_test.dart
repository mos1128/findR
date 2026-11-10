/// 孤儿媒体回收的验收网。
///
/// 两条边界必须同时成立：
/// - 过期且没有卡片引用的文件 → 删；
/// - 有卡片引用的、以及刚写进去还没插行的 → 留着。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:findr_app/capture/submit.dart';
import 'package:findr_app/platform/app_paths.dart';
import 'package:findr_app/platform/db.dart';
import 'package:findr_app/platform/media_gc.dart';
import 'package:flutter_test/flutter_test.dart';

late Directory _root;

void main() {
  setUp(() async {
    _root = await Directory.systemTemp.createTemp('findr_gc_');
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

  test('回收过期孤儿，保留有卡片的与刚写入的', () async {
    final db = openAndMigrateDb();
    final now = DateTime(2026, 9, 22, 12);
    final card = await persistCapture(
      db,
      CaptureSubmission(
        photos: <PendingPhoto>[
          PendingPhoto(webp: Uint8List.fromList(<int>[1, 2, 3])),
        ],
      ),
      now: now,
    );

    final liveDir = Directory(AppPaths.abs('files/cards/202609/${card.id}'));
    expect(liveDir.existsSync(), isTrue);

    final oldOrphan = Directory(
      AppPaths.abs('files/cards/202601/orphan-old'),
    )..createSync(recursive: true);
    File('${oldOrphan.path}/01.webp')
      ..writeAsBytesSync(<int>[1], flush: true)
      ..setLastModifiedSync(DateTime(2024, 1, 1));

    final freshOrphan = Directory(
      AppPaths.abs('files/cards/202601/orphan-new'),
    )..createSync(recursive: true);
    File('${freshOrphan.path}/01.webp').writeAsBytesSync(<int>[1], flush: true);

    final oldAudio = File(AppPaths.abs('files/audio/202601/dead.m4a'))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(<int>[1], flush: true)
      ..setLastModifiedSync(DateTime(2024, 1, 1));
    final freshAudio = File(AppPaths.abs('files/audio/202601/fresh.m4a'))
      ..writeAsBytesSync(<int>[1], flush: true);

    final removed = collectOrphanMedia(db, now: now);
    db.close();

    expect(removed, 2);
    expect(oldOrphan.existsSync(), isFalse);
    expect(oldAudio.existsSync(), isFalse);
    expect(freshOrphan.existsSync(), isTrue, reason: '刚写入的可能是正在录入的素材');
    expect(freshAudio.existsSync(), isTrue);
    expect(liveDir.existsSync(), isTrue, reason: '有卡片引用，绝不能删');
  });
}
