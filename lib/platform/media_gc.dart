/// 孤儿媒体回收。
///
/// 录入是「先写媒体、再插行」：进程在两步之间被杀、删卡时文件删到一半、
/// 导入写媒体后合并 DB 失败 —— 都会留下没有卡片引用的文件。
/// 它们不会被任何界面显示，却会跟着下一次备份一起被打包。
///
/// **不能看到「没有卡片」就立刻删**：正在录入的素材也是先有文件、后有行。
/// 所以只回收「最后修改时间早于 [minAge]（默认 24 小时）」的孤儿。
library;

import 'dart:io';

import 'package:findr_core/findr_core.dart';

import 'app_paths.dart';

/// 扫一遍 `files/cards` 与 `files/audio`，删掉过期孤儿。返回删除的数量。
int collectOrphanMedia(
  SqliteDriver db, {
  Duration minAge = const Duration(hours: 24),
  DateTime? now,
}) {
  if (!AppPaths.ready) return 0;
  final cutoff = (now ?? DateTime.now()).subtract(minAge);
  final ids = db
      .prepare('SELECT id FROM cards')
      .all()
      .map((r) => r['id'].toString())
      .toSet();

  var removed = 0;

  void removeCardDir(Directory dir) {
    final name = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (ids.contains(name)) return;
    try {
      final latest = _latestModification(dir);
      if (latest == null || latest.isAfter(cutoff)) return;
      dir.deleteSync(recursive: true);
      removed++;
    } catch (_) {
      // 单个目录删不掉不该阻塞其余回收
    }
  }

  final cardsRoot = Directory(AppPaths.abs('files/cards'));
  if (cardsRoot.existsSync()) {
    try {
      for (final month in cardsRoot.listSync().whereType<Directory>()) {
        try {
          for (final cardDir in month.listSync().whereType<Directory>()) {
            removeCardDir(cardDir);
          }
        } catch (_) {
          // 跳过读不了的月份目录
        }
      }
    } catch (_) {
      // 整个根目录读不了就放弃这一轮
    }
  }

  final audioRoot = Directory(AppPaths.abs('files/audio'));
  if (audioRoot.existsSync()) {
    try {
      for (final month in audioRoot.listSync().whereType<Directory>()) {
        try {
          for (final file in month.listSync().whereType<File>()) {
            final name = file.uri.pathSegments.where((s) => s.isNotEmpty).last;
            final id = name.split('.').first;
            if (ids.contains(id)) continue;
            if (file.lastModifiedSync().isAfter(cutoff)) continue;
            file.deleteSync();
            removed++;
          }
        } catch (_) {
          // 跳过读不了的月份目录
        }
      }
    } catch (_) {
      // 整个根目录读不了就放弃这一轮
    }
  }

  return removed;
}

/// 目录里最新的文件时间。**不看目录自身的 mtime**：
/// 目录时间在不同文件系统/平台上的更新时机不一致，而「里面的文件最后被改过」
/// 才是判断「是否还在写」的可靠信号。空目录退回目录自身的时间。
DateTime? _latestModification(Directory dir) {
  DateTime? latest;
  try {
    for (final entity in dir.listSync(recursive: true)) {
      try {
        final modified = entity.statSync().modified;
        if (latest == null || modified.isAfter(latest)) latest = modified;
      } catch (_) {
        // 单个文件 stat 失败不影响其余判断
      }
    }
  } catch (_) {
    // 目录读不了就交给调用方跳过
  }
  if (latest != null) return latest;
  try {
    return dir.statSync().modified;
  } catch (_) {
    return null;
  }
}
