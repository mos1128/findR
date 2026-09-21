/// 设备层自检 —— 把「只有真机才会暴露」的假设一次性验掉。
///
/// 对应 RN 的 `apps/mobile/src/platform/selfcheck.ts`，但**刻意不重复 core 已经验过的东西**：
/// FTS5 / trigram / 迁移 / 建表那七项收在 `findr_core` 的 `runCoreSelfCheck()` 里
/// （见 `Flutter迁移交接.md` §6.1），这里只放**只有在设备上才成立**的五项：
/// 真实库文件的 PRAGMA、外键真的会拦人、嵌套事务、真实文件系统的媒体往返、整库打包往返。
///
/// 为什么值得单独一层：备份是**唯一会真的碰文件系统的功能**，而 `dart test` 里跑的是内存媒体库
/// —— 「设备上真的能把图画进包里吗」只有这里能答。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:findr_core/findr_core.dart';

import 'app_paths.dart';
import 'db.dart';
import 'media.dart';

/// 设备层自检的结果：要么跑完了（[DeviceSelfCheckDone]），要么根本跑不了
/// （[DeviceSelfCheckUnavailable]，例如在 `flutter test` 里 —— 那时没有沙盒目录）。
///
/// **刻意分成两态而不是「塞一条失败项」**：跑不了不等于没通过，
/// 混在一起会让 `flutter test` 里永远是红的，久而久之就没人看这一屏了。
sealed class DeviceSelfCheckOutcome {
  const DeviceSelfCheckOutcome();
}

final class DeviceSelfCheckDone extends DeviceSelfCheckOutcome {
  const DeviceSelfCheckDone(this.items);

  final List<SelfCheckItem> items;

  bool get passed => items.every((i) => i.ok);

  int get failedCount => items.where((i) => !i.ok).length;

  String get verdict => passed ? '设备层通过' : '设备层 $failedCount 项失败';
}

final class DeviceSelfCheckUnavailable extends DeviceSelfCheckOutcome {
  const DeviceSelfCheckUnavailable(this.reason);

  final String reason;
}

/// 跑一遍设备层自检。
///
/// [db] 传进来就复用（界面里已有常驻连接时应当传）；不传则自己开一个真实库文件，
/// **并在结束时关掉**（自检不该长期占着库文件）。
Future<DeviceSelfCheckOutcome> runDeviceSelfCheck({Sqlite3Driver? db}) async {
  if (!AppPaths.ready) {
    return const DeviceSelfCheckUnavailable(
      '沙盒目录尚未初始化 —— 这是测试环境（或 main() 没 await AppPaths.init()）。\n'
      '这一组只能在真机上跑，不算失败。',
    );
  }

  final own = db == null;
  final Sqlite3Driver conn;
  try {
    conn = db ?? openFindrDb();
  } catch (e) {
    return DeviceSelfCheckUnavailable('打开库文件失败：$e');
  }

  final items = <SelfCheckItem>[];
  final store = const DeviceMediaStore();

  try {
    // 自检要能**独立跑**（真机上用户随时可能点进来，也可能在一个还没迁移过的库上跑）。
    // `migrate` 本身是幂等的，重复调用无副作用。
    try {
      migrate(conn);
    } catch (e) {
      return DeviceSelfCheckDone(<SelfCheckItem>[
        SelfCheckItem(name: '迁移（设备层前置）', ok: false, detail: '$e'),
      ]);
    }

    items.add(_checkPragmas(conn));
    items.add(_checkForeignKeys(conn));
    items.add(_checkNestedTransaction(conn));
    items.add(await _checkMediaRoundTrip(store));
    items.add(await _checkBackupRoundTrip(conn, store));
    return DeviceSelfCheckDone(items);
  } finally {
    // 临时表清干净：自检可以随时重跑，不能给库里留东西。
    try {
      conn.exec('DROP TABLE IF EXISTS __findr_sc');
    } catch (_) {
      // 清理失败不该掩盖真正的失败
    }
    if (own) conn.close();
  }
}

SelfCheckItem _checkPragmas(SqliteDriver db) {
  try {
    final journal = db.prepare('PRAGMA journal_mode').get()?['journal_mode']?.toString() ?? '?';
    final fk = db.prepare('PRAGMA foreign_keys').get()?['foreign_keys'];
    final fkOn = fk == 1;
    // WAL 也硬判：`attachPragmas` 明确设了它，设不上说明这个库文件所在的卷有问题，
    // 而「设了但没生效」正是最容易被忽略的一类假象。库文件路径一并报出来，方便排查。
    return SelfCheckItem(
      name: '真实库文件已打开并挂上 PRAGMA',
      ok: fkOn && journal.toLowerCase() == 'wal',
      detail: 'journal_mode=$journal（期望 wal）、foreign_keys=$fk（期望 1）、路径 ${AppPaths.abs(dbFileName)}',
    );
  } catch (e) {
    return SelfCheckItem(name: '真实库文件已打开并挂上 PRAGMA', ok: false, detail: '$e');
  }
}

SelfCheckItem _checkForeignKeys(SqliteDriver db) {
  try {
    var rejected = false;
    try {
      db
          .prepare('INSERT INTO locations (id, parent_id, name, sort) VALUES (?, ?, ?, ?)')
          .run(<Object?>['__sc_loc', '__sc_missing_parent', '自检占位', 0]);
    } catch (_) {
      rejected = true;
    }
    if (!rejected) {
      db.prepare('DELETE FROM locations WHERE id = ?').run(<Object?>['__sc_loc']);
      return const SelfCheckItem(
        name: '外键真的会拦人',
        ok: false,
        detail: '非法 parent_id 竟然写进去了 —— PRAGMA foreign_keys 没起作用',
      );
    }
    return const SelfCheckItem(
      name: '外键真的会拦人',
      ok: true,
      detail: '非法 parent_id 被拒',
    );
  } catch (e) {
    return SelfCheckItem(name: '外键真的会拦人', ok: false, detail: '$e');
  }
}

SelfCheckItem _checkNestedTransaction(SqliteDriver db) {
  try {
    db.exec('DROP TABLE IF EXISTS __findr_sc');
    db.exec('CREATE TABLE __findr_sc (v TEXT)');
    db.transaction(() {
      db.prepare('INSERT INTO __findr_sc (v) VALUES (?)').run(<Object?>['outer']);
      try {
        db.transaction(() {
          db.prepare('INSERT INTO __findr_sc (v) VALUES (?)').run(<Object?>['inner']);
          throw StateError('故意回滚内层');
        });
      } catch (_) {
        // 预期：内层回滚
      }
    });
    final vals = db
        .prepare('SELECT v FROM __findr_sc ORDER BY v')
        .all()
        .map((r) => r['v'].toString())
        .toList();
    final ok = vals.length == 1 && vals.first == 'outer';
    return SelfCheckItem(
      name: '嵌套事务走 SAVEPOINT（内层回滚不影响外层）',
      ok: ok,
      detail: ok ? '外层保留、内层已回滚' : '实际 [${vals.join(', ')}]（期望 [outer]）',
    );
  } catch (e) {
    return SelfCheckItem(
      name: '嵌套事务走 SAVEPOINT（内层回滚不影响外层）',
      ok: false,
      detail: '$e',
    );
  }
}

Future<SelfCheckItem> _checkMediaRoundTrip(MediaStorePort store) async {
  const name = '媒体端口真机读写往返（真实文件系统）';
  const rel = '__selfcheck/probe.bin';
  final probe = Uint8List.fromList(<int>[0, 1, 2, 250, 251, 252, 253, 254, 255]);
  try {
    store.write(rel, probe);
    final back = await store.read(rel);
    if (back == null) return const SelfCheckItem(name: name, ok: false, detail: '写完立刻读却是 null');
    if (back.length != probe.length) {
      return SelfCheckItem(name: name, ok: false, detail: '长度 ${back.length} ≠ ${probe.length}');
    }
    for (var i = 0; i < probe.length; i++) {
      if (back[i] != probe[i]) {
        return SelfCheckItem(name: name, ok: false, detail: '第 $i 字节 ${back[i]} ≠ ${probe[i]}');
      }
    }
    // exists 在端口里是可选的（不实现则退化），设备端实现了 —— 断言它真在
    if (store.exists?.call(rel) == false) {
      return const SelfCheckItem(name: name, ok: false, detail: 'exists() 返回 false');
    }
    if (await store.read('__selfcheck/不存在.bin') != null) {
      return const SelfCheckItem(name: name, ok: false, detail: '不存在的路径应返回 null');
    }
    return SelfCheckItem(name: name, ok: true, detail: '写入并读回 ${probe.length} 字节一致');
  } catch (e) {
    return SelfCheckItem(name: name, ok: false, detail: '$e');
  } finally {
    // 探针跑完即删，连同目录 —— 别在用户的沙盒里留垃圾
    try {
      final file = AppPaths.file(rel);
      if (file.existsSync()) file.deleteSync();
      final dir = AppPaths.parentOf(rel);
      if (dir != null && dir.existsSync()) dir.deleteSync();
    } catch (_) {
      // 清理失败不重要
    }
  }
}

/// 整库真打一次包：读全库 → 逐个读媒体 → ZIP → 容器头 → 再解包读回清单。
/// 这一条等于**把导出链路整条走一遍**，是设备层最有价值的一项。
///
/// 只读：`exportBackup` 不写任何表，媒体那侧也只读不写。
Future<SelfCheckItem> _checkBackupRoundTrip(SqliteDriver db, MediaStorePort store) async {
  const name = '整库打包 → 解包 → 读回清单（走完整条导出链路）';
  try {
    final started = DateTime.now();
    final result = await exportBackup(BackupDeps(db: db, media: store), now: DateTime.now());
    final entries = readZip(unpackContainer(result.bytes));
    ZipReadEntry? manifestEntry;
    for (final e in entries) {
      if (e.path == manifestName) {
        manifestEntry = e;
        break;
      }
    }
    if (manifestEntry == null) {
      return const SelfCheckItem(name: name, ok: false, detail: '包内没有 manifest.json');
    }
    final manifest = jsonDecode(utf8Decode(manifestEntry.data));
    final cards = manifest is Map && manifest['cards'] is List
        ? (manifest['cards'] as List).length
        : -1;
    if (cards != result.report.cards) {
      return SelfCheckItem(
        name: name,
        ok: false,
        detail: '清单里的卡片数 $cards 与报告里的 ${result.report.cards} 对不上',
      );
    }
    final ms = DateTime.now().difference(started).inMilliseconds;
    return SelfCheckItem(
      name: name,
      ok: true,
      detail:
          '卡片 ${result.report.cards} · 分类 ${result.report.categories} · 位置 ${result.report.locations} · '
          '别名 ${result.report.aliases} · 媒体 ${result.report.mediaWritten}/${result.report.mediaTotal} · '
          '整包 ${result.report.bytes} 字节 · 耗时 $ms ms',
    );
  } catch (e) {
    return SelfCheckItem(name: name, ok: false, detail: '$e');
  }
}
