/// 备份的「文件那一半」。
///
/// core 只负责「字节进字节出」（`backup/pack.dart`），落在哪个目录、怎么递给用户，
/// 是平台层的事。全库媒体只在两端各读一遍，中间不复制 —— 导出峰值内存 ≈ 整包 + 单文件。
///
/// ⚠️ **包里没有任何加密**（见 core 的 `backup/format.dart`）：
/// 它就是一层壳 + 标准 ZIP，拿到文件的人直接就能读到全部记忆。
/// 所以界面**必须**明说不加密（红条 + 导出前确认框），且只能往用户自己信得过的地方递。
///
/// ⚠️ **API Key 可以随包带走**（导出时界面上有开关）。Key 只有平台层够得着
/// （在 Keystore 里，见 `secure.dart`），所以「读出来塞进包 / 取回来写回去」都在这里：
/// 这是**唯一**该碰 Key 的一层，界面只决定带不带，不自己读写安全存储。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:findr_core/findr_core.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';

import 'app_paths.dart';
import 'media.dart';

const String backupExt = '.findrpack';
const String backupMime = 'application/octet-stream';

/// 只留最近几个备份：递出去之后那文件就没用了，反复导出不该把临时目录越堆越大。
const int keepBackups = 3;

Directory backupDir() => AppPaths.temp;

String _pad2(int n) => n.toString().padLeft(2, '0');

/// 文件名里的本地时间戳（给人看、给排序用，与写库的 `isoUtc()` 无关）。
/// ⚠️ 用本地时间：`20260921-1640` 比 UTC 的 `20260921-0840` 对人有用得多。
String backupStamp(DateTime d) {
  final l = d.toLocal();
  return '${l.year}${_pad2(l.month)}${_pad2(l.day)}-${_pad2(l.hour)}${_pad2(l.minute)}';
}

void purgeOldBackups() {
  try {
    final dir = backupDir();
    if (!dir.existsSync()) return;
    final packs =
        dir
            .listSync()
            .whereType<File>()
            .where((f) {
              final name = f.uri.pathSegments.last;
              return name.startsWith('findr-') && name.endsWith(backupExt);
            })
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path));
    for (final stale in packs.skip(keepBackups)) {
      stale.deleteSync();
    }
  } catch (_) {
    // 清理失败不该让导出失败
  }
}

final class ExportOutcome {
  const ExportOutcome({
    required this.path,
    required this.fileName,
    required this.report,
  });

  /// 文件在设备上的绝对路径，交给分享面板用。
  final String path;
  final String fileName;
  final ExportReport report;
}

/// 导出只报「打包」和「落盘」两段：core 的 `exportBackup` 是一整块
/// （读全库 → 逐个读媒体 → ZIP → 套容器头），中间不给回调，**所以不假装能报得更细**。
/// 现在最慢的是「把全库媒体逐个读进内存并拼进 ZIP」（图片多的库要几秒），
/// 界面靠秒表交代「还在动」，不靠进度条。
enum ExportPhase { packing, writing }

/// 取 App 版本号（写进备份 manifest 的 `appVersion`）。
///
/// ⚠️ **这个 Future 有可能永远不完成** —— 它走平台通道，在少数环境（没注册插件的
/// 测试宿主、个别定制 ROM）里那个调用可能迟迟不回包。
/// 所以：**调用方绝不能在关键路径上 await 它**。目前唯一的调用点是
/// `platform/runtime.dart` 的 `_fillVersion`，它是 `unawaited` 的 ——
/// 拿不到就一直空着，界面照常可用。
///
/// （这里刻意**不加 `timeout`**：`timeout` 会挂一个定时器，在 widget 测试里
/// 那个定时器必然「测试结束时仍 pending」而让用例失败。不阻塞比设超时更根本。）
Future<String?> appVersion() async {
  try {
    return (await PackageInfo.fromPlatform()).version;
  } catch (_) {
    // 取不到版本号不该让导出失败 —— manifest 里那个字段本来就可选
    return null;
  }
}

List<String> listAllAttachments() {
  if (!AppPaths.ready) return const <String>[];
  final doc = AppPaths.documents;
  final cardsDir = Directory('${doc.path}/files/cards');
  if (!cardsDir.existsSync()) return const <String>[];
  final rels = <String>[];
  final docNorm = doc.path.replaceAll(r'\', '/');
  for (final file in cardsDir.listSync(recursive: true).whereType<File>()) {
    final norm = file.path.replaceAll(r'\', '/');
    if (norm.startsWith('$docNorm/')) {
      final rel = norm.substring(docNorm.length + 1);
      if (rel.contains('/attachments/')) {
        rels.add(rel);
      }
    }
  }
  return rels;
}

Future<ExportOutcome> exportToFile(
  SqliteDriver db, {
  String? version,
  void Function(ExportPhase phase)? onPhase,

  /// 要随包带走的 API Key（键名 = `ApiKeySlot.storageKey`）。**null / 空 = 不带**。
  ///
  /// 不带是默认值 —— 「备份含 Key」是件有代价的事，只能由界面显式选择。
  Map<String, String>? secrets,
}) async {
  final now = DateTime.now();

  onPhase?.call(ExportPhase.packing);
  final result = await exportBackup(
    BackupDeps(db: db, media: const DeviceMediaStore(), appVersion: version),
    now: now,
    secrets: secrets,
    extraMediaPaths: listAllAttachments(),
  );

  onPhase?.call(ExportPhase.writing);
  final dir = backupDir();
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final name = 'findr-${backupStamp(now)}$backupExt';
  final file = File('${dir.path}/$name');
  if (file.existsSync()) file.deleteSync();
  file.writeAsBytesSync(result.bytes, flush: true);
  purgeOldBackups();

  return ExportOutcome(
    path: file.path,
    fileName: name,
    report: result.report,
  );
}

/// 打开系统分享面板。用户在这里可以「发送到微信 / 保存到云盘 / 存到文件」。
///
/// 不做可用性预探测：`share_plus` 没有等价的查询接口，而 Android/iOS 上它恒可用。
/// 真失败就让异常冒到界面去 —— **报一句真话比静默禁用按钮好**。
Future<void> shareBackup(String path, String fileName) async {
  await SharePlus.instance.share(
    ShareParams(
      files: <XFile>[XFile(path, mimeType: backupMime)],
      fileNameOverrides: <String>[fileName],
      title: '导出 Findr 备份（$fileName）',
      subject: 'Findr 备份 $fileName',
    ),
  );
}

/// 让用户挑一个备份文件。
///
/// **刻意用「全部类型」**（`FileType.any` → `*/*`）而不是限定后缀：Android 对自定义后缀
/// `.findrpack` 的类型判定不可靠，一旦限定，就会出现「文件明明在，选择器里却是灰的」。
/// 真正的把关放在 core 的 magic 校验里 —— 挑错文件会得到一句人话
/// （「不是有效的 .findrpack 文件」），比让人压根找不到文件好得多。
Future<PlatformFile?> pickBackupFile() =>
    FilePicker.pickFile(dialogTitle: '选择 .findrpack 备份文件');

/// 从挑到的文件里读整包字节。
///
/// 直读失败时先复制到本地再读：从微信/云盘「转存」过来的文件是 `content://` 虚拟文档，
/// 偶尔拿不到可读流。复制也失败就把**原始错误**抛出去 —— 别把「读不出」与「复制不了」
/// 混成一句含糊的话，那会让排查从几分钟变成几小时。
Future<Uint8List> readBackupBytes(PlatformFile file) async {
  try {
    return await file.xFile.readAsBytes();
  } catch (original) {
    try {
      final dir = backupDir();
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final src = file.path;
      if (src == null) rethrow;
      final local = File('${dir.path}/import$backupExt');
      if (local.existsSync()) local.deleteSync();
      await File(src).copy(local.path);
      try {
        return await local.readAsBytes();
      } finally {
        if (local.existsSync()) local.deleteSync();
      }
    } catch (_) {
      throw original is Exception ? original : StateError('$original');
    }
  }
}

/// 导入。core 侧的顺序是「先写媒体、再合并 DB」，所以这里不需要额外的事务包装 ——
/// 媒体写失败时 DB 一个字都没动。导入**不会删除本地任何数据**（同 id 按 `updated_at` 新者胜）。
Future<ImportResult> importFromBytes(SqliteDriver db, Uint8List bytes) =>
    importBackup(BackupDeps(db: db, media: const DeviceMediaStore()), bytes);
