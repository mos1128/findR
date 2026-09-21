/// 手工冒烟：把一份真实的 `.findrpack` 写到磁盘，供外部工具独立验证。
///
/// 为什么需要它：`test/backup/` 里的用例是我们**自己读写自己**（自证），
/// 而备份格式的第一性要求是「**产物是标准 zip，别的工具能打开**」——
/// 那只能用第三方实现来验。跑法：
///
/// ```
/// dart run tool/export_probe.dart [输出路径]
/// ```
///
/// 然后对它做独立检查，例如（等价于用户拿 7-Zip 打开）：
///
/// ```
/// python -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); \
///   print(z.namelist()); print('crc ok' if z.testzip() is None else 'CRC FAIL')" probe.findrpack
/// ```
library;

import 'dart:convert' show jsonEncode;
import 'dart:io';
import 'dart:typed_data';

import 'package:findr_core/findr_core.dart';

final class _MemMedia implements MediaStorePort {
  _MemMedia(this.files);

  final Map<String, Uint8List> files;

  @override
  Uint8List? read(String relPath) => files[relPath];

  @override
  void write(String relPath, Uint8List data) => files[relPath] = data;

  @override
  bool Function(String relPath)? get exists => (relPath) => files.containsKey(relPath);
}

Future<void> main(List<String> argv) async {
  final outPath = argv.isNotEmpty
      ? argv.first
      : '${Directory.systemTemp.path}${Platform.pathSeparator}findr-probe.findrpack';

  final db = Sqlite3Driver.openInMemory();
  migrate(db);

  final at = DateTime(2026, 9, 18, 12);
  final img = imageRelPath(at, 'c1', 0);
  final audio = audioRelPath(at, 'c2');
  final media = _MemMedia(<String, Uint8List>{
    img: Uint8List.fromList(<int>[1, 2, 3, 4, 5, 250, 251]),
    audio: Uint8List.fromList(<int>[9, 8, 7, 6]),
  });

  upsertLocation(db, const LocationNode(id: 'loc1', parentId: null, name: '主卧', sort: 0));
  upsertLocation(db, const LocationNode(id: 'loc2', parentId: 'loc1', name: '衣柜', sort: 0));

  createDraft(
    db,
    const CaptureInput(source: SourceKind.text, text: '备用手电筒放在主卧衣柜顶层'),
    id: 'c1',
    now: at,
  );
  db
      .prepare(
        'UPDATE cards SET entity = ?, desc_text = ?, images = ?, path_ids = ?, path_names = ?, '
        "tags = ?, updated_at = ? WHERE id = ?",
      )
      .run(<Object?>[
        '手电筒',
        '备用手电筒放在主卧衣柜顶层',
        jsonEncode(<String>[img]),
        jsonEncode(<String>['loc1', 'loc2']),
        '主卧/衣柜',
        jsonEncode(<String>['照明']),
        isoUtc(at),
        'c1',
      ]);
  createDraft(
    db,
    CaptureInput(source: SourceKind.voice, audio: audio),
    id: 'c2',
    now: at,
  );

  setSetting(db, 'search', <String, Object?>{'autoAnswer': true});
  setSetting(db, 'llm', <String, Object?>{
    'providerType': 'openai-compat',
    'baseUrl': 'http://192.168.1.9:7788',
    'model': 'qwen-vl-max',
    // ⚠️ 这行是 canary：导出**必须**把它挡在白名单/按键名剥除之外
    'apiKey': 'sk-LEAK-CANARY-0000',
  });

  final result = await exportBackup(BackupDeps(db: db, media: media, appVersion: 'probe'), now: at);
  File(outPath).writeAsBytesSync(result.bytes);

  stdout.writeln('写出：$outPath');
  stdout.writeln(
    '字节数 ${result.bytes.length}（头 ${backupHeaderLen} + 载荷 ${result.bytes.length - backupHeaderLen}）',
  );
  stdout.writeln('magic=${String.fromCharCodes(result.bytes.sublist(0, 5))}');
  stdout.writeln(
    'cards=${result.report.cards} media=${result.report.mediaWritten}/${result.report.mediaTotal} '
    'missing=${result.report.mediaMissing}',
  );
  db.close();
}
