/// 流式导出的设备侧验收：写出来的是标准 ZIP，能被原样导回去。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:findr_app/capture/submit.dart';
import 'package:findr_app/platform/app_paths.dart';
import 'package:findr_app/platform/backup.dart';
import 'package:findr_app/platform/db.dart';
import 'package:findr_core/findr_core.dart';
import 'package:flutter_test/flutter_test.dart';

late Directory _root;

void main() {
  setUp(() async {
    _root = await Directory.systemTemp.createTemp('findr_stream_');
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

  test('流式导出到文件 → 文件完整且能重新导入', () async {
    final db = openAndMigrateDb();
    final photoBytes = Uint8List.fromList(<int>[
      for (var i = 0; i < 40; i++) i,
    ]);
    await persistCapture(
      db,
      CaptureSubmission(
        text: '护照在主卧抽屉',
        photos: <PendingPhoto>[PendingPhoto(webp: photoBytes)],
      ),
    );

    final out = await exportToFile(db);
    final file = File(out.path);
    expect(file.existsSync(), isTrue);
    expect(
      out.report.bytes,
      file.lengthSync(),
      reason: '报告里的字节数必须与落盘文件一致',
    );

    final importedDb = openAndMigrateDb('imported.sqlite');
    final res = await importFromFile(importedDb, file);
    expect(res.report.cardsInserted, 1);

    final imported = listCards(importedDb).single;
    expect(imported.transcript, '护照在主卧抽屉');
    expect(imported.images, isNotEmpty);
    expect(AppPaths.file(imported.images!.single).readAsBytesSync(), photoBytes);

    importedDb.close();
    db.close();
  });
}
