/// 备份（`.findrpack`）—— 导出/导入全链路，17 个用例。
///
/// 这一层是「用户把文件拿走、再拿回来」的唯一通道，所以容错要求比别处高一档：
/// **任何校验失败都必须在写库/写文件之前抛掉**，绝不能出现「导入一半」。
///
/// 两条要点（对应交接 §6.2）：
/// - 明文方案**没有 GCM tag**，完整性全靠 ZIP 每个成员的 CRC32 ⇒ 那两条「改一位/截断」
///   的用例就是在钉住这唯一能抓损坏的机制；
/// - `settings` 导出走**白名单**（`SettingsKeys.all`），不是黑名单过滤 ⇒ 那条 canary
///   用例比加密时代更重要：文件是明文的，白名单一旦漏了就是直接泄露。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:findr_core/findr_core.dart';
import 'package:test/test.dart';

import '../helpers.dart';
import '../helpers/memory_media.dart';

final DateTime at = DateTime.parse('2026-09-18T04:00:00.000Z');

final String img = imageRelPath(at, 'c1', 0);
final String audio = audioRelPath(at, 'c2');
final Uint8List imgBytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 250, 251]);
final Uint8List audioBytes = Uint8List.fromList(<int>[9, 8, 7, 6]);

/// 一侧的「数据库 + 媒体库」组合。
final class Side {
  const Side({required this.deps, required this.media});

  final BackupDeps deps;
  final MemoryMedia media;
}

/// 导出侧：两份卡片、两级位置、一条别名、两个媒体文件。
Side sourceSide() {
  final db = makeDb();
  final media = MemoryMedia(<String, Uint8List>{img: imgBytes, audio: audioBytes});

  upsertLocation(db, const LocationNode(id: 'loc1', parentId: null, name: '主卧', sort: 0));
  upsertLocation(db, const LocationNode(id: 'loc2', parentId: 'loc1', name: '衣柜', sort: 0));

  insertCard(
    db,
    makeCard(
      id: 'c1',
      entity: '手电筒',
      desc: '备用手电筒放在主卧衣柜顶层',
      images: <String>[img],
      pathIds: <String>['loc1', 'loc2'],
      pathNames: '主卧/衣柜',
      tags: <String>['照明'],
      updatedAt: '2026-09-01T00:00:00.000Z',
      createdAt: '2026-09-01T00:00:00.000Z',
    ),
  );
  insertCard(
    db,
    makeCard(
      id: 'c2',
      entity: '买牙膏',
      categoryId: 'cat_todo',
      steps: const <StepItem>[StepItem(text: '看家里还缺什么', done: false)],
      audioPath: audio,
      source: SourceKind.voice,
      status: CardStatus.pendingTranscript,
      updatedAt: '2026-09-02T00:00:00.000Z',
      createdAt: '2026-09-02T00:00:00.000Z',
    ),
  );
  db
      .prepare('INSERT INTO aliases (id, kind, name, card_id) VALUES (?, ?, ?, ?)')
      .run(<Object?>['al1', 'entity', '电筒', 'c1']);

  return Side(deps: BackupDeps(db: db, media: media), media: media);
}

/// 导入侧：干净的库 + 空的媒体库。
Side targetSide() {
  final db = makeDb();
  final media = MemoryMedia();
  return Side(deps: BackupDeps(db: db, media: media), media: media);
}

Future<ExportResult> exportFrom(Side side) => exportBackup(side.deps, now: at);

/// 解出包里的 manifest 原始 JSON，用来检查「不该出现的东西有没有出现」。
///
/// 刻意返回**原始 Map**（而不是 `BackupManifest`）：要验的正是「键在不在」，
/// 转换会把这个信息抹掉。
Map<String, Object?> rawManifestOf(Uint8List bytes) {
  final entry = _firstWhereOrNull(readZip(unpackContainer(bytes)), (e) => e.path == manifestName);
  if (entry == null) throw StateError('测试前提不成立：包里没有 manifest.json');
  return (jsonDecode(utf8Decode(entry.data)) as Map).cast<String, Object?>();
}

T? _firstWhereOrNull<T>(Iterable<T> items, bool Function(T) test) {
  for (final item in items) {
    if (test(item)) return item;
  }
  return null;
}

/// 在整包字节里找一段字节序列（用于证明「内容就是明文」）。
bool containsBytes(Uint8List haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var hit = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

void main() {
  // ─────────────────────────────────────────────────────────────
  // 备份格式：明文容器
  // ─────────────────────────────────────────────────────────────

  group('备份格式：明文容器', () {
    test('头部是 magic + 版本，载荷是标准 ZIP', () async {
      final r = await exportFrom(sourceSide());
      final bytes = r.bytes;
      expect(backupHeaderLen, backupMagic.length + 2);
      expect(String.fromCharCodes(bytes.sublist(0, 5)), 'FINDR');
      expect(
        ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes)
            .getUint16(5, Endian.little),
        1,
      );
      expect(bytes.length, greaterThan(backupHeaderLen));

      // 载荷第一个本地头就是 ZIP 的签名 "PK\x03\x04"
      final payload = unpackContainer(bytes);
      expect(payload.sublist(0, 4), <int>[0x50, 0x4b, 0x03, 0x04]);
    });

    test('载荷是明文：中文原文能直接在整包字节里搜到（当前版本不加密）', () async {
      final r = await exportFrom(sourceSide());
      expect(containsBytes(r.bytes, utf8Encode('手电筒')), isTrue);
      expect(containsBytes(r.bytes, utf8Encode('备用手电筒放在主卧衣柜顶层')), isTrue);
    });

    test('非本格式的文件会被明确拒绝', () async {
      final side = targetSide();
      await expectLater(
        importBackup(side.deps, Uint8List(64)),
        throwsA(
          predicate((Object e) => e.toString().contains('不是 .findrpack')),
        ),
      );
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 备份：round-trip
  // ─────────────────────────────────────────────────────────────

  group('备份：round-trip', () {
    test('导出再导入后，卡片/分类/位置/别名与媒体文件都一致', () async {
      final src = sourceSide();
      final exported = await exportFrom(src);

      expect(exported.report.cards, 2);
      expect(exported.report.mediaTotal, 2);
      expect(exported.report.mediaWritten, 2);
      expect(exported.report.mediaMissing, isEmpty);

      final dst = targetSide();
      final imported = await importBackup(dst.deps, exported.bytes);

      expect(imported.report.cardsInserted, 2);
      expect(imported.manifestInfo.cards, 2);

      final c1 = getCard(dst.deps.db, 'c1')!;
      expect(c1.entity, '手电筒');
      expect(c1.images, <String>[img]);
      expect(c1.pathIds, <String>['loc1', 'loc2']);
      expect(c1.pathNames, '主卧/衣柜');

      final c2 = getCard(dst.deps.db, 'c2')!;
      expect(c2.status, CardStatus.pendingTranscript);
      expect(c2.source, SourceKind.voice);
      expect(c2.steps, const <StepItem>[StepItem(text: '看家里还缺什么', done: false)]);

      final locs = dst.deps.db
          .prepare('SELECT id, parent_id FROM locations ORDER BY id')
          .all();
      expect(locs, hasLength(2));
      expect(locs[0]['id'], 'loc1');
      expect(locs[0]['parent_id'], isNull);
      expect(locs[1]['id'], 'loc2');
      expect(locs[1]['parent_id'], 'loc1');

      final alias = dst.deps.db
          .prepare('SELECT name, card_id FROM aliases WHERE id = ?')
          .get(<Object?>['al1'])!;
      expect(alias['name'], '电筒');
      expect(alias['card_id'], 'c1');

      expect(dst.media.files[img], imgBytes);
      expect(dst.media.files[audio], audioBytes);
    });

    test('同一份包导入两次是幂等的，第二次不动任何数据', () async {
      final exported = await exportFrom(sourceSide());
      final dst = targetSide();
      await importBackup(dst.deps, exported.bytes);
      final second = await importBackup(dst.deps, exported.bytes);

      expect(second.report.cardsInserted, 0);
      expect(second.report.cardsUpdated, 0);
      expect(second.report.cardsKeptLocal, 2);
      expect(listCards(dst.deps.db), hasLength(2));
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 备份：完整性与边界
  // ─────────────────────────────────────────────────────────────

  group('备份：完整性与边界', () {
    // 明文方案没有 GCM tag 兜底，完整性全靠 ZIP 每个成员的 CRC32。
    // 这两条钉住那个兜底真的在工作 —— 它是这个版本唯一能抓损坏的机制。
    test('载荷被改一位：CRC 校验必须拦住，且不落任何数据', () async {
      final exported = await exportFrom(sourceSide());
      final tampered = Uint8List.fromList(exported.bytes);
      tampered[backupHeaderLen + 60] ^= 0x01; // 落在第一个成员（manifest.json）的数据里
      final dst = targetSide();
      await expectLater(
        importBackup(dst.deps, tampered),
        throwsA(predicate((Object e) => e.toString().contains('校验和不符'))),
      );
      expect(listCards(dst.deps.db), isEmpty);
      expect(dst.media.files, isEmpty);
    });

    test('文件被截断必须失败，且不落任何数据', () async {
      final exported = await exportFrom(sourceSide());
      final dst = targetSide();
      final truncated = Uint8List.fromList(
        exported.bytes.sublist(0, exported.bytes.length - 5),
      );
      await expectLater(importBackup(dst.deps, truncated), throwsA(isA<Exception>()));
      expect(listCards(dst.deps.db), isEmpty);
      expect(dst.media.files, isEmpty);
    });

    test('settings 走白名单：白名单外的设置项绝不进包（Key 也不从这条通道漏出去）', () async {
      final src = sourceSide();
      setSetting(src.deps.db, 'llm', <String, Object?>{
        'providerType': 'anthropic',
        'model': 'claude-opus-5',
        'apiKey': 'sk-LEAK-CANARY-1234567890',
      });
      setSetting(src.deps.db, 'tracking_id', <String, Object?>{'installId': 'CANARY-TRACKING'});

      final exported = await exportFrom(src);
      final manifest = rawManifestOf(exported.bytes);
      final dump = jsonEncode(manifest);

      expect(dump.contains('sk-LEAK-CANARY-1234567890'), isFalse);
      expect(dump.contains('CANARY-TRACKING'), isFalse);
      final settings = (manifest['settings']! as Map).cast<String, Object?>();
      expect(settings.containsKey('llm'), isTrue);
      expect(settings.containsKey('tracking_id'), isFalse);
      // 这条断言现在比加密时代更重要：文件是明文的，白名单一旦漏了就是直接泄露
      expect(containsBytes(exported.bytes, utf8Encode('sk-LEAK-CANARY-1234567890')), isFalse);
      // Key 走 `apiKeys` 那条单独通道，**不是** settings。
      // 「不传就不带」这条必须守住：默认不带，才谈得上界面上的开关有意义。
      expect(manifest.containsKey('apiKeys'), isFalse);
    });

    test('库里引用了但磁盘上已不存在的媒体：不阻断导出，但要如实报告', () async {
      final src = sourceSide();
      src.media.files.remove(audio);
      final r = await exportFrom(src);
      expect(r.report.mediaMissing, <String>[audio]);
      expect(r.report.mediaWritten, 1);
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 备份：随包带走 API Key
  //
  // 这一组钉的是「通道本身的开关」：**默认不带，只有调用方显式传了才带**。
  // 界面上那个「带上 Key」的勾选框，靠的就是这里。
  // ─────────────────────────────────────────────────────────────

  group('备份：随包带走 API Key', () {
    const llmKey = 'findr.llm.apiKey';
    const asrKey = 'findr.asr.apiKey';

    test('不传 secrets 时，manifest 里压根没有 apiKeys 键；导入返回空', () async {
      final src = sourceSide();
      final exported = await exportBackup(src.deps, now: at);
      expect(rawManifestOf(exported.bytes).containsKey('apiKeys'), isFalse);

      final res = await importBackup(targetSide().deps, exported.bytes);
      expect(res.apiKeys, isEmpty);
    });

    test('传了 secrets 才会进包，且导入能原样取回', () async {
      final src = sourceSide();
      final exported = await exportBackup(
        src.deps,
        now: at,
        secrets: <String, String>{llmKey: 'sk-llm-abc', asrKey: 'sk-asr-xyz'},
      );
      final manifest = rawManifestOf(exported.bytes);
      expect(manifest['apiKeys'], <String, Object?>{llmKey: 'sk-llm-abc', asrKey: 'sk-asr-xyz'});

      final res = await importBackup(targetSide().deps, exported.bytes);
      expect(res.apiKeys, <String, String>{llmKey: 'sk-llm-abc', asrKey: 'sk-asr-xyz'});
    });

    test('带 Key 的包是明文的：Key 原文能在整包字节里搜到（这是必须让用户知道的代价）', () async {
      final src = sourceSide();
      final exported = await exportBackup(
        src.deps,
        now: at,
        secrets: <String, String>{llmKey: 'sk-PLAINTEXT-CANARY'},
      );
      // 这不是在测试「加密有没有生效」—— 这一版**就是没有加密**。
      // 钉住它，是为了让「备份带 Key 会把密钥明文交给拿到文件的人」这句话有据可查，
      // 将来加了加密，这条会红 ⇒ 正好提醒加密那条路要跟上。
      expect(containsBytes(exported.bytes, utf8Encode('sk-PLAINTEXT-CANARY')), isTrue);
    });

    test('老包没有 apiKeys 键：导入照常成功，只是不带 Key', () async {
      final base = <String, Object?>{
        'format': 'findrpack',
        'formatVersion': 1,
        'schemaVersion': currentSchemaVersion(sourceSide().deps.db),
        'exportedAt': isoUtc(at),
        'cards': <Object?>[],
        'categories': <Object?>[],
        'locations': <Object?>[],
        'aliases': <Object?>[],
        'settings': <String, Object?>{},
        'media': <Object?>[],
      };
      final m = validateManifest(base);
      expect(m.apiKeys, isNull);
    });

    test('core 不自己读 Key：只搬调用方给的，多一把少一把都不会自作主张', () async {
      final src = sourceSide();
      final exported = await exportBackup(
        src.deps,
        now: at,
        secrets: <String, String>{}, // 显式给空 = 不带（与 null 同义）
      );
      // 空 map 也写进 JSON ⇒ 导入侧拿到空 map，语义是「带了但一把都没有」
      expect(rawManifestOf(exported.bytes)['apiKeys'], isEmpty);
      expect((await importBackup(targetSide().deps, exported.bytes)).apiKeys, isEmpty);
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 备份：导入合并策略
  // ─────────────────────────────────────────────────────────────

  group('备份：导入合并策略', () {
    test('不删除本地独有的数据', () async {
      final exported = await exportFrom(sourceSide());
      final dst = targetSide();
      insertCard(
        dst.deps.db,
        makeCard(
          id: 'local-only',
          entity: '只有本机有',
          updatedAt: '2026-09-10T00:00:00.000Z',
        ),
      );

      await importBackup(dst.deps, exported.bytes);

      final ids = listCards(dst.deps.db).map((c) => c.id).toList();
      expect(ids, contains('local-only'));
      expect(ids, contains('c1'));
    });

    test('同 id 冲突时 updated_at 新者胜（外来更新 → 覆盖）', () async {
      final src = sourceSide();
      final exported = await exportFrom(src);

      final dst = targetSide();
      insertCard(
        dst.deps.db,
        makeCard(
          id: 'c1',
          entity: '本机的旧版本',
          updatedAt: '2026-08-01T00:00:00.000Z',
        ),
      );
      final r = await importBackup(dst.deps, exported.bytes);

      expect(r.report.cardsUpdated, 1);
      expect(getCard(dst.deps.db, 'c1')!.entity, '手电筒');
    });

    test('同 id 冲突时 updated_at 新者胜（本地更新 → 保留）', () async {
      final src = sourceSide();
      final exported = await exportFrom(src);

      final dst = targetSide();
      insertCard(
        dst.deps.db,
        makeCard(
          id: 'c1',
          entity: '本机的新版本',
          updatedAt: '2026-12-31T00:00:00.000Z',
        ),
      );
      final r = await importBackup(dst.deps, exported.bytes);

      expect(r.report.cardsKeptLocal, 1);
      expect(getCard(dst.deps.db, 'c1')!.entity, '本机的新版本');
    });

    test('分类同名冲突：保留本地分类，并把卡片的 category_id 重映射到本地 id', () async {
      final src = sourceSide();
      // 造一个与外来的 cat_item 同名但不同 id 的本地分类，制造冲突：
      // 把本地那条预设的 id 改掉、名字留着 —— 于是外来包的 cat_item 会撞上「同名不同 id」
      final dst = targetSide();
      dst.deps.db
          .prepare(
            "UPDATE categories SET id = 'local_item', description = '本地版本' WHERE id = 'cat_item'",
          )
          .run();

      // 需要一个引用 cat_item 的卡：用 c2 之外的物品卡
      insertCard(
        src.deps.db,
        makeCard(
          id: 'c3',
          entity: '螺丝刀',
          categoryId: 'cat_item',
          updatedAt: '2026-09-03T00:00:00.000Z',
        ),
      );
      final exported = await exportFrom(src);

      final r = await importBackup(dst.deps, exported.bytes);

      expect(
        r.report.conflicts.any((c) => c.kind == 'category' && c.name == '物品存取'),
        isTrue,
      );
      expect(getCard(dst.deps.db, 'c3')!.categoryId, 'local_item');
      // 本地那条同名分类还在，没有被覆盖
      final rows = dst.deps.db
          .prepare("SELECT id FROM categories WHERE name = '物品存取'")
          .all();
      expect(rows.map((x) => x['id']).toList(), <Object?>['local_item']);
    });

    test('位置的父链会随重映射一起改写，path_names 跟着重算', () async {
      final src = sourceSide();
      final exported = await exportFrom(src);

      // 目标库里已有同名同父的『主卧』，但 id 不同 → 冲突 + 重映射
      final dst = targetSide();
      upsertLocation(
        dst.deps.db,
        const LocationNode(id: 'local_wz', parentId: null, name: '主卧', sort: 0),
      );

      final r = await importBackup(dst.deps, exported.bytes);

      expect(r.report.conflicts.any((c) => c.kind == 'location' && c.name == '主卧'), isTrue);
      final card = getCard(dst.deps.db, 'c1')!;
      expect(card.pathIds, <String>['local_wz', 'loc2']);
      expect(card.pathNames, '主卧/衣柜');
      final child = dst.deps.db
          .prepare('SELECT parent_id FROM locations WHERE id = ?')
          .get(<Object?>['loc2'])!;
      expect(child['parent_id'], 'local_wz');
    });

    test('本地已有设置不被外来包冲掉，缺失的设置才会补上', () async {
      final src = sourceSide();
      setSetting(src.deps.db, 'search', <String, Object?>{'autoAnswer': true});
      setSetting(src.deps.db, 'capture', <String, Object?>{
        'visionDefault': false,
        'visionLast': false,
        'maxAnalyzeImages': 6,
      });
      // 老安装的残留：settings 表里可能还留着一行没人读的 pipeline
      setSetting(src.deps.db, 'pipeline', <String, Object?>{'confirmThreshold': 0.9});
      final exported = await exportFrom(src);

      // 它已从 SettingsKeys 里删掉 ⇒ 掉出白名单，老残留不会被带到别人的机器上
      final settingsKeys =
          ((rawManifestOf(exported.bytes)['settings']! as Map).keys.map((k) => k.toString()).toList())
            ..sort();
      expect(settingsKeys, <String>['capture', 'search']);

      final dst = targetSide();
      setSetting(dst.deps.db, 'search', <String, Object?>{'autoAnswer': false});

      final r = await importBackup(dst.deps, exported.bytes);

      expect(r.report.settingsKeptLocal, 1);
      expect(r.report.settingsWritten, 1);
      expect(
        jsonDecode(
          dst.deps.db
                  .prepare("SELECT value FROM settings WHERE key = 'search'")
                  .get()!['value']
              as String,
        ),
        <String, Object?>{'autoAnswer': false},
      );
      expect(
        jsonDecode(
          dst.deps.db
                  .prepare("SELECT value FROM settings WHERE key = 'capture'")
                  .get()!['value']
              as String,
        ),
        <String, Object?>{'visionDefault': false, 'visionLast': false, 'maxAnalyzeImages': 6},
      );
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 备份：manifest 校验
  // ─────────────────────────────────────────────────────────────

  group('备份：manifest 校验', () {
    test('包里 schema 版本比本机新时必须拒绝导入', () {
      final base = <String, Object?>{
        'format': 'findrpack',
        'formatVersion': 1,
        'schemaVersion': 999,
        'exportedAt': isoUtc(at),
        'cards': <Object?>[],
        'categories': <Object?>[],
        'locations': <Object?>[],
        'aliases': <Object?>[],
        'settings': <String, Object?>{},
        'media': <Object?>[],
      };
      expect(
        () => validateManifest(base),
        throwsA(predicate((Object e) => e.toString().contains('更新的版本'))),
      );
    });

    test('缺少必需数组字段时拒绝', () {
      expect(
        () => validateManifest(<String, Object?>{'format': 'findrpack', 'schemaVersion': 1}),
        throwsA(predicate((Object e) => e.toString().contains('缺少数组字段'))),
      );
      expect(
        () => validateManifest(<String, Object?>{'format': 'wrong', 'schemaVersion': 1}),
        throwsA(predicate((Object e) => e.toString().contains('标识不符'))),
      );
    });
  });
}
