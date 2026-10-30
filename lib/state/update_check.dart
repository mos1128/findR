/// 启动时静默检查更新（12 小时节流）—— 首页的设置入口据此显示红点。
///
/// **为什么要节流**：发布接口按 IP 限流（GitHub 未登录 60 次/小时/IP）。
/// 12 小时内不重复请求；节流期内直接用上次记下的 tag 判断红点。
///
/// 查不到（断网 / 限流）**不写节流时间** —— 断一次网不该让接下来一天都不再检查。
library;

import 'package:findr_core/findr_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../platform/runtime.dart';
import '../platform/update.dart';

/// 上次检查时间（epoch 毫秒）与当时发现的最新 tag。
///
/// **刻意不放进 `SettingsKeys.all`** —— 那是备份导出的白名单，
/// 这两项是本机缓存，跟着备份换机没有意义。
const String kUpdateCheckAtKey = 'update_check_at';
const String kUpdateLatestTagKey = 'update_latest_tag';

/// GitHub 下载加速：开关与地址前缀（同样是本机偏好，不进备份）。
///
/// 用户自己搭了加速服务的，把地址填进来即可；留空或关掉就走 GitHub 原站。
const String kUpdateAccelEnabledKey = 'update_accel_enabled';
const String kUpdateAccelPrefixKey = 'update_accel_prefix';

const bool kUpdateAccelEnabledDefault = true;
const String kUpdateAccelPrefixDefault = 'https://gh-proxy.com/';

bool readUpdateAccelEnabled(SqliteDriver db) =>
    getSetting<bool>(db, kUpdateAccelEnabledKey) ?? kUpdateAccelEnabledDefault;

String readUpdateAccelPrefix(SqliteDriver db) =>
    getSetting<String>(db, kUpdateAccelPrefixKey) ?? kUpdateAccelPrefixDefault;

void writeUpdateAccel(SqliteDriver db, {required bool enabled, required String prefix}) {
  setSetting(db, kUpdateAccelEnabledKey, enabled);
  setSetting(db, kUpdateAccelPrefixKey, prefix.trim());
}

/// 生效的加速前缀：关掉、留空、或不是 http(s) 地址 ⇒ `null`（直接走原站）。
String? effectiveUpdateAccelPrefix(SqliteDriver db) {
  if (!readUpdateAccelEnabled(db)) return null;
  final raw = readUpdateAccelPrefix(db).trim();
  if (raw.isEmpty) return null;
  if (!raw.startsWith('http://') && !raw.startsWith('https://')) return null;
  return raw.endsWith('/') ? raw : '$raw/';
}

/// 自动检查的最小间隔（每天最多两次）。
const Duration updateAutoCheckInterval = Duration(hours: 12);

/// 记下这次检查的结果。手动点「检查更新」后也要调它，红点才不会说谎。
void recordUpdateCheck(SqliteDriver db, {required String? latestTag}) {
  setSetting(db, kUpdateCheckAtKey, DateTime.now().millisecondsSinceEpoch);
  if (latestTag == null) {
    deleteSetting(db, kUpdateLatestTagKey);
  } else {
    setSetting(db, kUpdateLatestTagKey, latestTag);
  }
}

/// 启动时的自动检查：有新版本返回它的 tag，否则 `null`。
///
/// [client] / [now] 只为测试注入。
Future<String?> runAutoUpdateCheck({
  required SqliteDriver db,
  required String currentVersion,
  required int currentBuild,
  http.Client? client,
  DateTime? now,
}) async {
  final at = now ?? DateTime.now();
  final lastAt = getSetting<int>(db, kUpdateCheckAtKey) ?? 0;
  if (at.millisecondsSinceEpoch - lastAt < updateAutoCheckInterval.inMilliseconds) {
    final tag = getSetting<String>(db, kUpdateLatestTagKey);
    return tag == null ? null : _newerTagOrNull(tag, currentVersion);
  }

  final res = await checkForUpdate(
    currentVersion: currentVersion,
    currentBuild: currentBuild,
    client: client,
  );
  switch (res) {
    case UpdateAvailable(:final info):
      recordUpdateCheck(db, latestTag: info.tag);
      return info.tag;
    case UpToDate():
      recordUpdateCheck(db, latestTag: null);
      return null;
    case UpdateCheckFailed():
      // 不写节流：下次启动再试
      return null;
  }
}

/// 节流期内只存了 tag：按版本号比一次（`compareVersions` 会剥掉 `v` 前缀）。
String? _newerTagOrNull(String tag, String currentVersion) =>
    compareVersions(tag, currentVersion) > 0 ? tag : null;

/// 当前生效的 GitHub 加速前缀（`null` = 不加速）。设置里改完记得 `ref.invalidate`。
final updateAccelPrefixProvider = Provider<String?>(
  (ref) => effectiveUpdateAccelPrefix(ref.watch(dbProvider)),
);

/// 供设置入口显示红点。版本号还没取到时返回 null，取到后会自动重跑。
final updateHintProvider = FutureProvider<String?>((ref) async {
  final rt = await ref.watch(runtimeProvider.future);
  final version = rt.version;
  if (version == null) return null;
  return runAutoUpdateCheck(
    db: ref.watch(dbProvider),
    currentVersion: version,
    currentBuild: int.tryParse(rt.buildNumber ?? '') ?? 0,
  );
});
