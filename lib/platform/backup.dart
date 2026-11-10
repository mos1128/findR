/// 备份的「文件那一半」。
///
/// core 只负责「字节进字节出」（`backup/pack.dart`），落在哪个目录、怎么递给用户，
/// 是平台层的事。全库媒体只在两端各读一遍，中间不复制 —— 导出峰值内存 ≈ 整包 + 单文件。
///
/// **备份是全量的**：API Key 也一并带走（导出时没有开关）。Key 只有平台层够得着
/// （在 Keystore 里，见 `secure.dart`），所以「读出来塞进包 / 取回来写回去」都在这里：
/// 这是**唯一**该碰 Key 的一层，界面只负责触发，不自己读写安全存储。
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

/// 导出只报「打包」和「落盘」两段。现在 core 是流式写文件，两段其实是交织的，
/// 这两个值只用于界面文案；进度靠秒表交代「还在动」，不假装有精确百分比。
enum ExportPhase { packing, writing }

/// 取 App 的版本号与构建号（现在版本号是三段 `X.Y.Z`，构建号恒为 1）。
///
/// 版本号写进备份 manifest 的 `appVersion`；两个值一起喂给运行时快照 ——
/// 设置页拿它显示版本，检查更新拿它跟远端比。日常发版只靠版本号的**最后一位**变化
/// 来区分新旧；构建号只在「远端 tag 带 `+N`」时才有意义。
///
/// ⚠️ **这个 Future 有可能永远不完成** —— 它走平台通道，在少数环境（没注册插件的
/// 测试宿主、个别定制 ROM）里那个调用可能迟迟不回包。
/// 所以：**调用方绝不能在关键路径上 await 它**。目前唯一的调用点是
/// `platform/runtime.dart` 的 `_fillVersion`，它是 `unawaited` 的 ——
/// 拿不到就一直空着，界面照常可用。
///
/// （这里刻意**不加 `timeout`**：`timeout` 会挂一个定时器，在 widget 测试里
/// 那个定时器必然「测试结束时仍 pending」而让用例失败。不阻塞比设超时更根本。）
Future<(String?, String?)> appVersionInfo() async {
  try {
    final info = await PackageInfo.fromPlatform();
    return (info.version, info.buildNumber);
  } catch (_) {
    // 取不到不该让任何调用方失败 —— manifest 里那个字段本来就可选，
    // 设置页则退回展示兜底文案
    return (null, null);
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

  /// 随包带走的 API Key（键名 = `ApiKeySlot.storageKey`）。
  ///
  /// 平台层总是传入本机全部 Key；空 map 表示本机没有配置。
  Map<String, String>? secrets,
}) async {
  final now = DateTime.now();

  onPhase?.call(ExportPhase.packing);
  final dir = backupDir();
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final name = 'findr-${backupStamp(now)}$backupExt';
  final file = File('${dir.path}/$name');
  if (file.existsSync()) file.deleteSync();

  // 流式写盘：每个块 `await writeFrom`，磁盘慢时自然背压，不会把整包堆在内存里。
  final raf = await file.open(mode: FileMode.write);
  try {
    final report = await exportBackupStream(
      BackupDeps(db: db, media: const DeviceMediaStore(), appVersion: version),
      now: now,
      secrets: secrets,
      extraMediaPaths: listAllAttachments(),
      write: (bytes) => raf.writeFrom(bytes),
    );
    await raf.flush();
    await raf.close();
    onPhase?.call(ExportPhase.writing);
    purgeOldBackups();
    return ExportOutcome(path: file.path, fileName: name, report: report);
  } catch (e) {
    try {
      await raf.close();
    } catch (_) {
      // 关闭失败不掩盖原始错误
    }
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // 半截文件删不掉也不能盖住真正的失败原因
    }
    rethrow;
  }
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

/// 备份文件的随机访问实现：只读当前需要的那一段。
final class FileBackupSource implements BackupByteSource {
  FileBackupSource._(this._raf, this._length);

  static Future<FileBackupSource> open(File file) async {
    final raf = await file.open();
    try {
      return FileBackupSource._(raf, await raf.length());
    } catch (_) {
      await raf.close();
      rethrow;
    }
  }

  final RandomAccessFile _raf;
  final int _length;

  @override
  Future<int> length() async => _length;

  @override
  Future<Uint8List> read(int offset, int count) async {
    if (offset < 0 || count < 0 || offset + count > _length) {
      throw RangeError('读取越界：offset=$offset, count=$count, length=$_length');
    }
    if (count == 0) return Uint8List(0);
    await _raf.setPosition(offset);
    return _raf.read(count);
  }

  Future<void> close() => _raf.close();
}

/// 把挑到的文件落到本地临时文件，再用随机访问流式导入。
///
/// 大多数情况下 `file.path` 就是一个真实文件，直接复制即可；从微信/云盘转存来的
/// `content://` 虚拟文档没有可用的文件路径时，交给 `XFile.saveTo` 流式落盘。
Future<File> materializeBackupFile(PlatformFile file) async {
  final dir = backupDir();
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final local = File('${dir.path}/import$backupExt');
  if (local.existsSync()) local.deleteSync();

  final src = file.path;
  if (src != null && src.isNotEmpty && File(src).existsSync()) {
    await File(src).copy(local.path);
  } else {
    await file.xFile.saveTo(local.path);
  }
  return local;
}

/// 从本地文件流式导入。坏包在第一遍校验时就会抛，不会写任何媒体。
Future<ImportResult> importFromFile(SqliteDriver db, File file) async {
  final source = await FileBackupSource.open(file);
  try {
    return await importBackupStream(
      BackupDeps(db: db, media: const DeviceMediaStore()),
      source,
    );
  } finally {
    await source.close();
  }
}

/// 设置页入口：平台文件 → 本地临时文件 → 流式导入 → 清理临时文件。
Future<ImportResult> importFromPlatformFile(
  SqliteDriver db,
  PlatformFile file,
) async {
  final local = await materializeBackupFile(file);
  try {
    return await importFromFile(db, local);
  } finally {
    try {
      if (local.existsSync()) local.deleteSync();
    } catch (_) {
      // 临时文件删不掉不影响导入结果
    }
  }
}

/// 从内存字节导入（测试与自检用；UI 走 [importFromPlatformFile] 的流式路径）。
Future<ImportResult> importFromBytes(SqliteDriver db, Uint8List bytes) =>
    importBackup(BackupDeps(db: db, media: const DeviceMediaStore()), bytes);
