import 'dart:convert';

import 'driver.dart';

/// settings 表只存非机密项（JSON 值）；API Key 一律走安全存储，
/// 导出备份也永不包含（技术设计四「Key 与配置分离」）。
///
/// 逐字对应 `packages/core/src/db/settings.ts`（43 行）。

T? getSetting<T>(SqliteDriver db, String key) {
  final row = db.prepare('SELECT value FROM settings WHERE key = ?').get([key]);
  if (row == null) return null;
  try {
    return jsonDecode(row['value']!.toString()) as T;
  } catch (_) {
    return null;
  }
}

void setSetting(SqliteDriver db, String key, Object? value) {
  db
      .prepare(
        'INSERT INTO settings (key, value) VALUES (?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      )
      .run([key, jsonEncode(value)]);
}

void deleteSetting(SqliteDriver db, String key) {
  db.prepare('DELETE FROM settings WHERE key = ?').run([key]);
}

Map<String, Object?> listSettings(SqliteDriver db) {
  final rows = db.prepare('SELECT key, value FROM settings').all();
  final out = <String, Object?>{};
  for (final row in rows) {
    try {
      out[row['key']!.toString()] = jsonDecode(row['value']!.toString());
    } catch (_) {
      // 坏值不阻塞其余设置读取
    }
  }
  return out;
}
